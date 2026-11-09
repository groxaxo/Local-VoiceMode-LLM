#!/usr/bin/env python3
"""Provision pinned public MLX STT checkpoints; no private model dependency."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile

PARAKEET_REPO = "transcriber-app/parakeet-tdt-0.6b-v3-mlx-8bit"
PARAKEET_REV = "b56210e2fad422736810524963c24b5e2a1985ab"
BARK_REPO = "ConwayResearch/Underdog-Bark-3.0-Pro"
BARK_REV = "4b5c51e04aa8d16dda9ecdff71bc29f7360149e4"
BARK_Q8_SHA = "b7d005f04532c1c23ed04010a3e7f442d7eac2fd44457823a4c055f30f785366"
PARAKEET_SHA = "41abe1e55db0aefcc9788b5e9afb8b51333b6744415f672d3f6b7cb4a08b1dfe"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify(path, expected):
    if not path.is_file() or digest(path) != expected:
        raise RuntimeError("Model weight SHA-256 verification failed: " + str(path))


def prepare(backend, output):
    from huggingface_hub import snapshot_download
    expected = BARK_Q8_SHA if backend == "bark-mlx" else PARAKEET_SHA
    if output.exists():
        verify(output/"model.safetensors", expected)
        return output
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="mlx-stt-", dir=output.parent) as temporary:
        stage = Path(temporary)/"checkpoint"
        if backend == "parakeet-mlx":
            source = Path(snapshot_download(PARAKEET_REPO, revision=PARAKEET_REV,
                          allow_patterns=["*.json", "*.safetensors", "README.md", "LICENSE*", "NOTICE*"]))
            verify(source/"model.safetensors", PARAKEET_SHA)
            shutil.copytree(source, stage)
        else:
            from convert_bark_mlx8 import convert_bark
            source = Path(snapshot_download(BARK_REPO, revision=BARK_REV,
                          allow_patterns=["model.safetensors","config.json","mlx/config.json",
                                          "tokenizer*.json","NOTICE","README.md","LICENSE*"]))
            verify(source/"model.safetensors", "6f84b33e63ebd1851e910e8b2fe299d29f5e0efc6f57e84d92d2f79af464e0e5")
            convert_bark(source, stage)
        verify(stage/"model.safetensors", expected)
        (stage/"local-voicemode-source.json").write_text(json.dumps(dict(
            repo=BARK_REPO if backend=="bark-mlx" else PARAKEET_REPO,
            revision=BARK_REV if backend=="bark-mlx" else PARAKEET_REV,
            weight_sha256=expected,
            changes="MLX affine 8-bit conversion, group size 64" if backend=="bark-mlx" else "Unmodified checkpoint weights"),indent=2)+"\n")
        # Commit only a fully converted and verified checkpoint.
        os.rename(stage, output)
    return output


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend",choices=("parakeet-mlx","bark-mlx"),required=True)
    parser.add_argument("--output",type=Path,required=True)
    args=parser.parse_args()
    print(prepare(args.backend,args.output))


if __name__=="__main__":
    main()
