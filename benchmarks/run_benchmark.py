#!/usr/bin/env python3
"""
OpenCode Voice Service — reproducible CPU benchmark.

Measures, on whatever hardware you run it on:
  * Silero VAD   — per-frame inference time (if the voice venv is available)
  * Parakeet STT — real-time factor at 3 utterance lengths
  * Supertonic 3 TTS — real-time factor at 8 (normal) and 20 (high) steps

It talks to the *running* local services (STT :5093, TTS :8766) over HTTP, so
start them first (they auto-start via systemd/launchd after `setup.sh`).

Usage:
    python benchmarks/run_benchmark.py
    python benchmarks/run_benchmark.py --tts-url http://127.0.0.1:8766 \
        --stt-url http://127.0.0.1:5093 --runs 5 --out benchmarks/RESULTS.md

Pure standard library for the HTTP parts. The VAD micro-benchmark is optional
and only runs if `silero-vad` + `torch` are importable (e.g. the installed
~/.config/opencode/tts-venv); otherwise it is skipped with a note.
"""
import argparse, io, json, platform, statistics, subprocess, sys, time, urllib.request, uuid, wave
from datetime import datetime, timezone

SENTENCES = {
    "short (10 words)": "Hey, can you run that test for me real quick?",
    "medium (22 words)": "I just finished setting up the local voice pipeline and it "
                          "runs entirely on the CPU without touching the cloud at all.",
    "long (45 words)": "The whole point of this project is privacy and speed on commodity "
                        "hardware. You speak, a neural voice detector catches the end of your "
                        "sentence, a local model transcribes it, your language model answers, "
                        "and a local synthesizer reads the reply back to you.",
}


def wav_duration(b: bytes) -> float:
    w = wave.open(io.BytesIO(b))
    return w.getnframes() / w.getframerate()


def post_json(url: str, obj: dict, timeout: int = 120):
    data = json.dumps(obj).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    t = time.perf_counter()
    body = urllib.request.urlopen(req, timeout=timeout).read()
    return time.perf_counter() - t, body


def post_wav(url: str, wav: bytes, model: str, timeout: int = 120):
    boundary = "----b" + uuid.uuid4().hex
    parts = [
        f'--{boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\n{model}\r\n'.encode(),
        (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="a.wav"\r\n'
         f'Content-Type: audio/wav\r\n\r\n').encode() + wav + b"\r\n",
        f"--{boundary}--\r\n".encode(),
    ]
    req = urllib.request.Request(url, data=b"".join(parts),
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    t = time.perf_counter()
    body = urllib.request.urlopen(req, timeout=timeout).read()
    return time.perf_counter() - t, body


def cpu_name() -> str:
    try:
        out = subprocess.check_output(["lscpu"], text=True)
        for line in out.splitlines():
            if line.startswith("Model name:"):
                return line.split(":", 1)[1].strip()
    except Exception:
        pass
    return platform.processor() or platform.machine()


def bench_tts(tts_url, voice, steps, runs):
    rows = []
    cache = {}
    for label, text in SENTENCES.items():
        times, wav = [], None
        for _ in range(runs):
            dt, wav = post_json(f"{tts_url}/v1/audio/speech", {
                "input": text, "voice": voice, "response_format": "wav",
                "stream": False, "total_steps": steps, "speed": 1.05})
            times.append(dt)
        dur = wav_duration(wav)
        med = statistics.median(times)
        cache[label] = wav
        rows.append((label, dur, med, med / dur))
    return rows, cache


def bench_stt(stt_url, wavs, model, runs):
    rows = []
    for label, wav in wavs.items():
        dur = wav_duration(wav)
        times, text = [], ""
        for _ in range(runs):
            dt, body = post_wav(f"{stt_url}/v1/audio/transcriptions", wav, model)
            times.append(dt)
            text = json.loads(body).get("text", "")
        med = statistics.median(times)
        rows.append((label, dur, med, med / dur, text.strip()))
    return rows


def bench_vad(runs=200):
    try:
        import torch
        from silero_vad import load_silero_vad
    except Exception as e:
        return None, f"skipped ({e.__class__.__name__}: run with the voice venv to include VAD)"
    m = load_silero_vad(onnx=True)
    frame = torch.zeros(512)
    for _ in range(5):
        m(frame, 16000)
    ts = []
    for _ in range(runs):
        t = time.perf_counter(); m(frame, 16000); ts.append(time.perf_counter() - t)
    return statistics.median(ts) * 1000, None  # ms/frame


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tts-url", default="http://127.0.0.1:8766")
    ap.add_argument("--stt-url", default="http://127.0.0.1:5093")
    ap.add_argument("--stt-model", default="parakeet-tdt-0.6b-v3")
    ap.add_argument("--voice", default="F4")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--out", default="benchmarks/RESULTS.md")
    args = ap.parse_args()

    cpu = cpu_name()
    print(f"Host CPU: {cpu}")
    print(f"Runs per measurement: {args.runs} (median reported)\n")

    vad_ms, vad_note = bench_vad()

    print("Supertonic 3 TTS — normal (8 steps)…")
    tts8, wavs = bench_tts(args.tts_url, args.voice, 8, args.runs)
    print("Supertonic 3 TTS — high quality (20 steps)…")
    tts20, _ = bench_tts(args.tts_url, args.voice, 20, args.runs)
    print("Parakeet STT…")
    stt = bench_stt(args.stt_url, wavs, args.stt_model, args.runs)

    # ---- render markdown ----
    L = []
    L.append("# Benchmark results\n")
    L.append(f"- **Host CPU:** {cpu}")
    L.append(f"- **Mode:** CPU only, no GPU")
    L.append(f"- **Voice:** {args.voice} · **Runs:** {args.runs} (median)")
    L.append(f"- **Date:** {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}\n")

    if vad_ms is not None:
        L.append(f"**Silero VAD:** {vad_ms:.3f} ms per 512-sample frame (32 ms of audio) — "
                 f"~{32/vad_ms:.0f}× realtime\n")
    else:
        L.append(f"**Silero VAD:** {vad_note}\n")

    L.append("### Parakeet STT")
    L.append("| Utterance | Audio | Latency (median) | RTF | Speed |")
    L.append("|-----------|-------|------------------|-----|-------|")
    for label, dur, med, rtf, _text in stt:
        L.append(f"| {label} | {dur:.2f}s | {med*1000:.0f} ms | {rtf:.3f} | {1/rtf:.1f}× |")
    L.append("")

    L.append("### Supertonic 3 TTS")
    L.append("| Reply | Audio | Normal (8 steps) | RTF | High (20 steps) | RTF |")
    L.append("|-------|-------|------------------|-----|-----------------|-----|")
    for (label, dur, m8, r8), (_, _, m20, r20) in zip(tts8, tts20):
        L.append(f"| {label} | {dur:.2f}s | {m8*1000:.0f} ms | {r8:.3f} | "
                 f"{m20*1000:.0f} ms | {r20:.3f} |")
    L.append("")
    L.append("_RTF = synthesis time ÷ audio duration (lower is faster; <1.0 is faster than realtime)._")

    md = "\n".join(L) + "\n"
    with open(args.out, "w") as f:
        f.write(md)
    print("\n" + md)
    print(f"Wrote {args.out}")


if __name__ == "__main__":
    main()
