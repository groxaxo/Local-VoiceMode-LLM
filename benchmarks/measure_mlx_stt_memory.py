#!/usr/bin/env python3
"""Measure MLX GPU active-memory high-water marks in a fresh process per model.

Apple Silicon has unified memory. MLX peak active allocations exclude allocator
cache, CPU/Python memory and other apps. Sampled active+cache is a sampled allocator
estimate, not an exact system-wide VRAM metric.
"""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import resource
import threading
import time


def digest(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--model", type=Path, required=True)
    ap.add_argument("--audio", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args()
    os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1")
    import mlx.core as mx
    import numpy as np
    import soundfile as sf
    from mlx_audio.stt import load
    wave, rate = sf.read(args.audio, dtype="float32")
    assert rate == 16000 and wave.ndim == 1 and len(wave) > 0
    assert np.isfinite(wave).all()
    mx.set_default_device(mx.gpu)
    samples = []
    stop = threading.Event()
    def sample():
        while not stop.is_set():
            samples.append(mx.get_active_memory() + mx.get_cache_memory())
            stop.wait(0.002)
    thread = threading.Thread(target=sample, daemon=True)
    thread.start()
    try:
        mx.reset_peak_memory()
        model = load(str(args.model), strict=True, model_type="parakeet")
        mx.eval(model.parameters())
        mx.synchronize()
        load_peak = mx.get_peak_memory()
        loaded_active = mx.get_active_memory()
        phases = []
        for duration in (4, 30, 60, 300):
            audio = np.tile(wave, int(np.ceil(duration * rate / len(wave))))[:duration * rate]
            data = mx.array(np.concatenate([np.zeros(4000, np.float32), audio]))
            mx.eval(data)
            mx.reset_peak_memory()
            for repeat in range(2):
                result = model.generate(data, dtype=mx.bfloat16, chunk_duration=30.0,
                                        overlap_duration=2.0, verbose=False)
                mx.synchronize()
                assert result.text.strip()
            phases.append(dict(audio_seconds=duration, repeats=2,
                               peak_active_bytes=mx.get_peak_memory(),
                               active_after_bytes=mx.get_active_memory(),
                               cache_after_bytes=mx.get_cache_memory()))
            del data, result
        result = dict(
            complete=True, platform=platform.platform(), device="Apple M5 GPU / unified memory",
            versions={p:importlib.metadata.version(p) for p in ("mlx","mlx-audio")},
            model=str(args.model.resolve()), config_sha256=digest(args.model/"config.json"),
            weight_sha256={p.name:digest(p) for p in args.model.glob("*.safetensors")},
            audio_sha256=digest(args.audio), load_peak_active_bytes=load_peak,
            loaded_active_bytes=loaded_active, phases=phases,
            peak_active_bytes=max([load_peak]+[p["peak_active_bytes"] for p in phases]),
            sampled_active_plus_cache_bytes=max(samples),
            peak_process_rss_bytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
            settings=dict(chunk_seconds=30,overlap_seconds=2,padding_seconds=0.25,activations="bfloat16"),
            note="Peak active GPU memory is exact for these workloads; allocator active+cache is sampled every 2 ms. Neither is whole-system VRAM. RSS is process memory.")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result,indent=2)+"\n")
        print(json.dumps(result,indent=2))
    finally:
        stop.set()
        thread.join()


if __name__ == "__main__":
    main()
