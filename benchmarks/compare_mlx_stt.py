#!/usr/bin/env python3
"""Compare local MLX Parakeet-family checkpoints on identical hashed audio.

Requires mlx-audio, soundfile, jiwer and num2words in an Apple Silicon venv.
The JSON manifest is a list of objects with id, group, language, reference,
audio_path and audio_sha256. Audio must already be mono PCM at 16 kHz.
Run each checkpoint in a separate process; model loading is timed separately.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import re
import resource
import statistics
import time
import unicodedata


def normalize(text, language, fold_accents=False):
    from num2words import num2words
    text = unicodedata.normalize("NFC", text).casefold().replace("’", "'")
    text = re.sub(r"\b\d+\b", lambda m: num2words(int(m[0]), lang=language), text)
    text = " ".join(re.sub(r"[^\w\s']", " ", text).split())
    if fold_accents:
        text = "".join(c for c in unicodedata.normalize("NFD", text)
                       if unicodedata.category(c) != "Mn")
    return text


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--manifest", type=Path, required=True)
    ap.add_argument("--model", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--repeats", type=int, default=2)
    args = ap.parse_args()
    if args.repeats < 1:
        ap.error("--repeats must be positive")
    if not args.model.is_dir():
        ap.error("--model must be an existing local checkpoint directory")
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    import jiwer
    import mlx.core as mx
    import numpy as np
    import soundfile as sf
    from mlx_audio.stt import load
    clips = json.loads(args.manifest.read_text())
    if not clips or len({x["id"] for x in clips}) != len(clips):
        raise ValueError("Manifest must contain unique nonempty clips")
    prepared = []
    for clip in clips:
        path = Path(clip["audio_path"])
        if digest(path) != clip["audio_sha256"]:
            raise ValueError(f"Audio hash mismatch: {clip['id']}")
        audio, rate = sf.read(path, dtype="float32")
        if rate != 16000 or audio.ndim != 1 or not len(audio) or not np.isfinite(audio).all():
            raise ValueError(f"Expected finite nonempty mono 16 kHz: {clip['id']}")
        prepared.append((clip, audio))
    mx.set_default_device(mx.gpu)
    started = time.perf_counter()
    model = load(str(args.model.resolve()), strict=True, model_type="parakeet")
    mx.eval(model.parameters())
    mx.synchronize()
    load_seconds = time.perf_counter() - started

    def infer(audio):
        data = mx.array(np.concatenate([np.zeros(4000, np.float32), audio]))
        started = time.perf_counter()
        text = model.generate(data, dtype=mx.bfloat16, chunk_duration=None, verbose=False).text.strip()
        mx.synchronize()
        return text, time.perf_counter() - started

    _, first_seconds = infer(prepared[0][1])
    rows = []
    for clip, audio in prepared:
        predictions = [infer(audio) for _ in range(args.repeats)]
        if len({p[0] for p in predictions}) != 1:
            raise RuntimeError(f"Nondeterministic output: {clip['id']}")
        hypothesis = predictions[0][0]
        scores = []
        for fold in (False, True):
            ref = normalize(clip["reference"], clip["language"], fold)
            hyp = normalize(hypothesis, clip["language"], fold)
            score = jiwer.process_words(ref, hyp)
            scores.append((score.hits + score.substitutions + score.deletions,
                           score.substitutions + score.deletions + score.insertions))
        rows.append({**clip, "hypothesis": hypothesis, "audio_seconds": len(audio) / rate,
                     "reference_words": scores[0][0], "word_errors": scores[0][1],
                     "accent_folded_errors": scores[1][1],
                     "seconds": [p[1] for p in predictions],
                     "median_seconds": statistics.median(p[1] for p in predictions)})
    summary = {}
    for group in sorted({r["group"] for r in rows}):
        selected = [r for r in rows if r["group"] == group]
        words = sum(r["reference_words"] for r in selected)
        seconds = sum(r["median_seconds"] for r in selected)
        duration = sum(r["audio_seconds"] for r in selected)
        summary[group] = {
            "clips": len(selected), "reference_words": words,
            "word_errors": sum(r["word_errors"] for r in selected),
            "wer": sum(r["word_errors"] for r in selected) / words,
            "accent_folded_wer": sum(r["accent_folded_errors"] for r in selected) / words,
            "audio_seconds": duration, "warm_inference_seconds": seconds,
            "times_realtime": duration / seconds}
    result = {
        "complete": True, "model_path": str(args.model.resolve()),
        "manifest_sha256": digest(args.manifest),
        "config_sha256": digest(args.model / "config.json"),
        "weight_sha256": {p.name: digest(p) for p in args.model.glob("*.safetensors")},
        "platform": platform.platform(), "python": platform.python_version(),
        "versions": {n: importlib.metadata.version(n) for n in
                     ("mlx", "mlx-audio", "jiwer", "num2words", "soundfile")},
        "load_seconds": load_seconds, "first_inference_seconds": first_seconds,
        "peak_process_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "peak_mlx_memory_bytes": mx.get_peak_memory(),
        "settings": {"padding_seconds": 0.25, "activations": "bfloat16",
                     "chunk_duration": None, "language_hint": None, "repeats": args.repeats},
        "normalization": "NFC lowercase, punctuation removed, integer tokens verbalized; accents retained.",
        "summary": summary, "rows": rows}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "rows"}, indent=2))


if __name__ == "__main__":
    main()
