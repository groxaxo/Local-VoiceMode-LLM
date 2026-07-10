#!/usr/bin/env python3
"""Silero-VAD microphone recorder used by the local voice-mode clients.

The process emits JSON lines on stdout. In one-shot mode it exits after the
first utterance; continuous mode emits one ``speech_end`` event per turn.
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import platform
import signal
import sys
import threading
import time
import wave
from pathlib import Path
from typing import Deque

import numpy as np
import sounddevice as sd
import torch
from silero_vad import VADIterator, load_silero_vad

FRAME_SIZE = 512
SAMPLE_RATE = 16_000


class RingBuffer:
    """Fixed-capacity audio buffer addressed with absolute sample positions."""

    def __init__(self, capacity_frames: int = 3000):
        if capacity_frames <= 0:
            raise ValueError("capacity_frames must be positive")
        self.capacity = capacity_frames
        self.frames: Deque[np.ndarray] = collections.deque()
        # Total samples appended since the last clear. This must never decrease
        # when an old frame is evicted, otherwise VAD sample coordinates drift.
        self._total = 0
        self._retained = 0

    def append(self, frame: np.ndarray) -> None:
        copied = np.asarray(frame, dtype=np.float32).copy()
        self.frames.append(copied)
        self._total += len(copied)
        self._retained += len(copied)
        while len(self.frames) > self.capacity:
            self._retained -= len(self.frames.popleft())

    @property
    def first_sample(self) -> int:
        return self._total - self._retained

    @property
    def end_sample(self) -> int:
        return self._total

    def slice(self, start_sample: int, end_sample: int) -> np.ndarray:
        start_sample = max(start_sample, self.first_sample)
        end_sample = min(end_sample, self.end_sample)
        if end_sample <= start_sample:
            return np.array([], dtype=np.float32)

        pieces: list[np.ndarray] = []
        cursor = self.first_sample
        for frame in self.frames:
            frame_end = cursor + len(frame)
            if frame_end > start_sample and cursor < end_sample:
                start = max(0, start_sample - cursor)
                end = min(len(frame), end_sample - cursor)
                if end > start:
                    pieces.append(frame[start:end])
            cursor = frame_end
        return np.concatenate(pieces) if pieces else np.array([], dtype=np.float32)

    def clear(self) -> None:
        self.frames.clear()
        self._total = 0
        self._retained = 0


def normalize_audio(
    audio: np.ndarray,
    target_rms_dbfs: float = -20,
    max_gain: float = 4,
    ceiling: float = 0.98,
) -> np.ndarray:
    if len(audio) == 0:
        return audio
    rms = float(np.sqrt(np.mean(np.square(audio, dtype=np.float64))))
    if not np.isfinite(rms) or rms < 1e-10:
        return audio
    target = 10 ** (target_rms_dbfs / 20)
    return np.clip(audio * min(max_gain, target / rms), -ceiling, ceiling)


def save_wav(path: str, audio: np.ndarray, normalize: bool = True) -> None:
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if normalize:
        audio = normalize_audio(audio)
    pcm = (np.clip(audio, -1.0, 1.0) * 32767).astype(np.int16)
    with wave.open(str(destination), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(pcm.tobytes())


def unique_output_path(output_dir: str, output_file: str) -> str:
    requested = Path(output_file)
    suffix = requested.suffix or ".wav"
    name = f"{requested.stem}-{os.getpid()}-{time.time_ns()}{suffix}"
    return str(Path(output_dir).expanduser() / name)


def list_devices() -> None:
    for index, device in enumerate(sd.query_devices()):
        if device["max_input_channels"] > 0:
            print(
                f"[{index}] {device['name']}  "
                f"inputs={int(device['max_input_channels'])}  "
                f"default_sr={int(device['default_samplerate'])}",
                file=sys.stderr,
            )


def find_mic(query: str | None = None) -> int | None:
    devices = sd.query_devices()
    blocked = ("nomachine", "virtualbox", "vmware", "virtual audio", "vb-audio")

    def acceptable(index: object) -> bool:
        if not isinstance(index, (int, np.integer)):
            return False
        try:
            device = devices[int(index)]
        except (IndexError, TypeError):
            return False
        name = str(device["name"]).lower()
        return device["max_input_channels"] > 0 and not any(word in name for word in blocked)

    if query:
        needle = query.casefold()
        for index, device in enumerate(devices):
            if acceptable(index) and needle in str(device["name"]).casefold():
                return index
        return None

    try:
        default_input = sd.default.device[0]
    except (AttributeError, IndexError, TypeError):
        default_input = None
    if acceptable(default_input):
        return int(default_input)

    if platform.system() == "Darwin":
        for index, device in enumerate(devices):
            name = str(device["name"]).casefold()
            if acceptable(index) and "macbook" in name and "microphone" in name:
                return index

    for index, _device in enumerate(devices):
        if acceptable(index):
            return index

    # Last resort: expose an otherwise-blocked real input instead of failing.
    for index, device in enumerate(devices):
        if device["max_input_channels"] > 0:
            return index
    return None


def emit_json(event: str, **values: object) -> None:
    print(json.dumps({"event": event, "timestamp": time.time(), **values}), flush=True)


class VADRecorder:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.output_path = unique_output_path(args.output_dir, args.output_file)
        self.pre_speech_padding = int(args.pre_speech_ms * SAMPLE_RATE / 1000)
        self.max_duration_frames = max(1, int(args.max_duration_s * SAMPLE_RATE / FRAME_SIZE))
        self.vad: VADIterator | None = None
        self.ring = RingBuffer(capacity_frames=max(3000, self.max_duration_frames + 64))
        self.stream: sd.InputStream | None = None
        self._stop_event = threading.Event()
        self._lock = threading.RLock()
        self.speech_active = False
        self.speech_start_sample = 0
        self.frames_since_speech = 0
        self._heard_speech = False
        self._listen_start = 0.0
        self._ignore_until = 0.0
        self._activated = False
        self._vad_offset = 0

    def load_vad(self) -> None:
        self.vad = VADIterator(
            load_silero_vad(),
            threshold=self.args.vad_threshold,
            sampling_rate=SAMPLE_RATE,
            min_silence_duration_ms=self.args.min_silence_ms,
            speech_pad_ms=30,
        )

    def _reset_vad_at_current_frame(self) -> None:
        assert self.vad is not None
        self._vad_offset = max(0, self.ring.end_sample - FRAME_SIZE)
        self.vad.reset_states()
        self.speech_active = False
        self.frames_since_speech = 0

    def process_frame(self, frame: np.ndarray) -> None:
        assert self.vad is not None
        self.ring.append(frame)
        now = time.time()
        if self._ignore_until and now < self._ignore_until:
            return
        if self._ignore_until:
            self._ignore_until = 0.0
            with self._lock:
                self._reset_vad_at_current_frame()

        result = self.vad(torch.from_numpy(frame).unsqueeze(0))
        with self._lock:
            if self.speech_active:
                self.frames_since_speech += 1
                if self.frames_since_speech >= self.max_duration_frames:
                    # ring.end_sample is already in the recorder's absolute sample
                    # coordinate system; adding _vad_offset here corrupts the slice.
                    self._finalize_turn(self.ring.end_sample, reason="max_duration")
                    self.speech_active = False
                    return

            if result is None:
                return
            if "start" in result:
                self.speech_active = True
                self.speech_start_sample = int(result["start"]) + self._vad_offset
                self.frames_since_speech = 0
                self._heard_speech = True
                if self.args.barge_in:
                    emit_json("barge_in", sample=self.speech_start_sample)
                    self._stop_event.set()
            elif "end" in result:
                self._finalize_turn(int(result["end"]) + self._vad_offset)
                self.speech_active = False

    def _finalize_turn(self, end_sample: int, reason: str | None = None) -> None:
        assert self.vad is not None
        start = max(self.ring.first_sample, self.speech_start_sample - self.pre_speech_padding)
        audio = self.ring.slice(start, end_sample)
        duration_ms = len(audio) * 1000 / SAMPLE_RATE
        if duration_ms < 100:
            # Do not poison future VAD coordinates after rejecting a tiny event.
            self.vad.reset_states()
            self.ring.clear()
            self._vad_offset = 0
            self.frames_since_speech = 0
            return

        save_wav(self.output_path, audio)
        payload: dict[str, object] = {
            "file": self.output_path,
            "duration_ms": round(duration_ms),
        }
        if reason:
            payload["reason"] = reason
        emit_json("speech_end", **payload)

        if self.args.oneshot:
            self._stop_event.set()
        self.vad.reset_states()
        self.ring.clear()
        self._vad_offset = 0
        self.frames_since_speech = 0

    def _check_idle_timeout(self) -> bool:
        timeout = self.args.idle_timeout_s
        if timeout <= 0 or self._heard_speech:
            return False
        elapsed = time.time() - self._listen_start
        if elapsed < timeout:
            return False
        emit_json("idle_timeout", elapsed_s=round(elapsed, 1))
        return True

    def audio_callback(self, indata, frames, time_info, status) -> None:
        del frames, time_info
        if self._stop_event.is_set():
            raise sd.CallbackStop()
        if status and self.args.debug:
            print(f"[vad] status: {status}", file=sys.stderr)
        mono = np.asarray(indata, dtype=np.float32).reshape(-1)
        for offset in range(0, len(mono) - FRAME_SIZE + 1, FRAME_SIZE):
            self.process_frame(mono[offset : offset + FRAME_SIZE])

    def _activate_now(self, *_args: object) -> None:
        now = time.time()
        self._activated = True
        self._ignore_until = now
        self._listen_start = now
        self._heard_speech = False

    def run(self) -> None:
        device = self.args.mic_device
        if device is None:
            device = find_mic(self.args.mic_query)
        if device is None:
            emit_json("error", message="No input audio device found")
            raise SystemExit(1)

        if self.args.debug:
            print(f"[vad] device [{device}]: {sd.query_devices(device)['name']}", file=sys.stderr)

        if hasattr(signal, "SIGUSR1"):
            try:
                signal.signal(signal.SIGUSR1, self._activate_now)
            except (ValueError, OSError):
                pass

        self.load_vad()
        if self.args.ready_delay_ms > 0 and not self._activated:
            self._ignore_until = time.time() + self.args.ready_delay_ms / 1000
        if not self._activated:
            self._listen_start = time.time()
        emit_json("listening")

        self.stream = sd.InputStream(
            device=device,
            channels=1,
            samplerate=SAMPLE_RATE,
            blocksize=FRAME_SIZE * 2,
            callback=self.audio_callback,
            dtype=np.float32,
        )
        with self.stream:
            while not self._stop_event.is_set():
                sd.sleep(100)
                if self._check_idle_timeout():
                    self._stop_event.set()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Silero VAD voice recorder")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--oneshot", action="store_true", default=True)
    mode.add_argument("--continuous", action="store_true")
    parser.add_argument("--output-dir", default=os.getenv("TMPDIR", "/tmp"))
    parser.add_argument("--output-file", default="opencode-turn.wav")
    parser.add_argument("--min-silence-ms", type=int, default=700)
    parser.add_argument("--vad-threshold", type=float, default=0.5)
    parser.add_argument("--pre-speech-ms", type=int, default=800)
    parser.add_argument("--ready-delay-ms", type=int, default=0)
    parser.add_argument("--max-duration-s", type=float, default=30)
    parser.add_argument("--idle-timeout-s", type=float, default=0)
    parser.add_argument("--mic-device", type=int)
    parser.add_argument("--mic-query")
    parser.add_argument("--list-devices", action="store_true")
    parser.add_argument("--print-selected-mic", action="store_true")
    parser.add_argument("--barge-in", action="store_true")
    parser.add_argument("--debug", action="store_true")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    if args.list_devices:
        list_devices()
        return
    if args.print_selected_mic:
        index = args.mic_device if args.mic_device is not None else find_mic(args.mic_query)
        if index is None:
            print("No suitable input device found")
            return
        try:
            info = sd.query_devices(index)
            print(
                f"[{index}] {info.get('name', '?')}  "
                f"inputs={int(info.get('max_input_channels', 0))}  "
                f"default_sr={int(info.get('default_samplerate', 0))}"
            )
        except Exception as error:
            print(f"[{index}] (query error: {error})")
        return
    if args.continuous:
        args.oneshot = False
    VADRecorder(args).run()


if __name__ == "__main__":
    main()
