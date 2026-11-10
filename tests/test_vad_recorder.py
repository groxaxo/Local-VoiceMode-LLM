"""Focused regression tests for VAD recorder buffer/sample accounting."""

from __future__ import annotations

import importlib.util
import json
import signal
import sys
import threading
import types
from pathlib import Path

import numpy as np
import pytest


# vad_recorder imports optional runtime packages at module import time. Stub the
# hardware/model-specific pieces so the pure buffering logic is testable in CI.
sounddevice = types.ModuleType("sounddevice")
sounddevice.CallbackStop = RuntimeError
ns = types.SimpleNamespace(device=(None, None))
sounddevice.default = ns
sounddevice.query_devices = lambda *_args, **_kwargs: []
sounddevice.InputStream = object
sounddevice.sleep = lambda _ms: None
sys.modules.setdefault("sounddevice", sounddevice)

torch = types.ModuleType("torch")
torch.from_numpy = lambda value: value
sys.modules.setdefault("torch", torch)

silero_vad = types.ModuleType("silero_vad")
silero_vad.VADIterator = object
silero_vad.load_silero_vad = lambda: object()
sys.modules.setdefault("silero_vad", silero_vad)

MODULE_PATH = Path(__file__).parents[1] / "service" / "vad_recorder.py"
spec = importlib.util.spec_from_file_location("vad_recorder", MODULE_PATH)
assert spec and spec.loader
vad_recorder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vad_recorder)
RingBuffer = vad_recorder.RingBuffer


def frame(value: float, length: int = 4) -> np.ndarray:
    return np.full(length, value, dtype=np.float32)


def test_eviction_preserves_absolute_sample_coordinates() -> None:
    ring = RingBuffer(capacity_frames=2)
    ring.append(frame(1))
    ring.append(frame(2))
    ring.append(frame(3))

    assert ring.first_sample == 4
    assert ring.end_sample == 12
    np.testing.assert_array_equal(ring.slice(4, 12), np.concatenate([frame(2), frame(3)]))


def test_slice_clamps_to_retained_window() -> None:
    ring = RingBuffer(capacity_frames=2)
    ring.append(frame(1))
    ring.append(frame(2))
    ring.append(frame(3))

    np.testing.assert_array_equal(ring.slice(0, 8), frame(2))
    np.testing.assert_array_equal(ring.slice(10, 99), frame(3)[2:])


def test_clear_resets_coordinate_space() -> None:
    ring = RingBuffer(capacity_frames=1)
    ring.append(frame(1))
    ring.clear()
    ring.append(frame(9, length=2))

    assert ring.first_sample == 0
    assert ring.end_sample == 2
    np.testing.assert_array_equal(ring.slice(0, 2), frame(9, length=2))


def test_invalid_capacity_is_rejected() -> None:
    try:
        RingBuffer(capacity_frames=0)
    except ValueError:
        pass
    else:
        raise AssertionError("zero-capacity buffers must be rejected")


@pytest.fixture
def recorder(monkeypatch):
    args = vad_recorder.build_parser().parse_args(["--mic-device", "0", "--ready-delay-ms", "700"])
    instance = vad_recorder.VADRecorder(args)
    # Test signal registration without changing pytest's own signal handlers.
    monkeypatch.setattr(vad_recorder.signal, "signal", lambda *_args: None)
    return instance


def test_listening_event_waits_for_model_and_stream_startup(recorder, monkeypatch):
    events = []
    model_loading = threading.Event()
    model_ready = threading.Event()
    stream_starting = threading.Event()
    stream_ready = threading.Event()
    failures = []

    def load_vad():
        model_loading.set()
        assert model_ready.wait(3)
        events.append("model-loaded")

    class Stream:
        active = True

        def __init__(self, **_kwargs):
            events.append("stream-created")

        def start(self):
            stream_starting.set()
            assert stream_ready.wait(3)
            # Even a slow stream startup must not consume the cue guard time.
            assert recorder._ignore_until == float("inf")
            events.append("stream-started")

        def close(self):
            events.append("stream-closed")

    def emit(event, **_values):
        assert recorder._ignore_until == pytest.approx(recorder._listen_start + .7)
        events.append(event)
        recorder._request_stop()

    def run():
        try:
            recorder.run()
        except BaseException as error:
            failures.append(error)

    monkeypatch.setattr(recorder, "load_vad", load_vad)
    monkeypatch.setattr(vad_recorder.sd, "InputStream", Stream)
    monkeypatch.setattr(vad_recorder, "emit_json", emit)
    worker = threading.Thread(target=run)
    worker.start()
    try:
        assert model_loading.wait(3)
        assert events == []
        model_ready.set()
        assert stream_starting.wait(3)
        assert events == ["model-loaded", "stream-created"]
    finally:
        model_ready.set()
        stream_ready.set()
        worker.join(3)
    assert not worker.is_alive()
    assert failures == []
    assert events == ["model-loaded", "stream-created", "stream-started", "listening", "stream-closed"]


@pytest.mark.parametrize("failure_stage", ["model", "construct", "start", "inactive"])
def test_initialization_failure_never_emits_listening(recorder, monkeypatch, failure_stage):
    events = []
    closed = []

    def load_vad():
        if failure_stage == "model":
            raise RuntimeError("model failed")

    class Stream:
        active = False

        def __init__(self, **_kwargs):
            if failure_stage == "construct":
                raise RuntimeError("construct failed")

        def start(self):
            if failure_stage == "start":
                raise RuntimeError("start failed")

        def close(self):
            closed.append(True)

    monkeypatch.setattr(recorder, "load_vad", load_vad)
    monkeypatch.setattr(vad_recorder.sd, "InputStream", Stream)
    monkeypatch.setattr(vad_recorder, "emit_json", lambda event, **_values: events.append(event))
    message = "failed to start" if failure_stage == "inactive" else f"{failure_stage} failed"
    with pytest.raises(RuntimeError, match=message):
        recorder.run()
    assert events == []
    assert closed == ([True] if failure_stage in {"start", "inactive"} else [])


def test_main_reports_initialization_error_as_json(recorder, monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", ["vad_recorder.py", "--mic-device", "0"])
    monkeypatch.setattr(vad_recorder, "VADRecorder", lambda _args: recorder)

    def fail():
        raise RuntimeError("input unavailable")

    monkeypatch.setattr(recorder, "load_vad", fail)
    with pytest.raises(SystemExit) as result:
        vad_recorder.main()
    assert result.value.code == 1
    event = json.loads(capsys.readouterr().out)
    assert event["event"] == "error"
    assert event["message"] == "input unavailable"


@pytest.mark.parametrize("stop_during", ["model", "start", "capture"])
def test_shutdown_closes_stream_without_announcing_unready_capture(recorder, monkeypatch, stop_during):
    events = []
    handlers = {}

    def stop():
        handlers[signal.SIGTERM]()

    def load_vad():
        if stop_during == "model":
            stop()

    class Stream:
        active = True

        def __init__(self, **_kwargs):
            events.append("stream-created")

        def start(self):
            if stop_during == "start":
                stop()

        def close(self):
            events.append("stream-closed")

    monkeypatch.setattr(vad_recorder.signal, "signal", lambda sig, handler: handlers.__setitem__(sig, handler))
    monkeypatch.setattr(recorder, "load_vad", load_vad)
    monkeypatch.setattr(vad_recorder.sd, "InputStream", Stream)
    monkeypatch.setattr(vad_recorder.sd, "sleep", lambda _ms: stop())
    monkeypatch.setattr(vad_recorder, "emit_json", lambda event, **_values: events.append(event))
    recorder.run()
    assert events == {
        "model": [],
        "start": ["stream-created", "stream-closed"],
        "capture": ["stream-created", "listening", "stream-closed"],
    }[stop_during]


def test_unexpected_stream_shutdown_reports_failure_and_closes_device(recorder, monkeypatch):
    events = []

    class Stream:
        active = True

        def __init__(self, **_kwargs):
            pass

        def start(self):
            pass

        def close(self):
            events.append("stream-closed")

    monkeypatch.setattr(recorder, "load_vad", lambda: None)
    monkeypatch.setattr(vad_recorder.sd, "InputStream", Stream)
    monkeypatch.setattr(vad_recorder.sd, "sleep", lambda _ms: setattr(recorder.stream, "active", False))
    monkeypatch.setattr(vad_recorder, "emit_json", lambda event, **_values: events.append(event))
    with pytest.raises(RuntimeError, match="stopped unexpectedly"):
        recorder.run()
    assert events == ["listening", "stream-closed"]
