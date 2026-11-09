# Optional Mac MLX speech recognition and peak GPU memory

Both Parakeet v3 MLX 8-bit and Underdog Bark 3.0 Pro MLX 8-bit passed native
installation and real transcription on the M5 MacBook Air (24 GB), macOS 27.0.1,
on 10 November 2026. ONNX CPU remains the default.

## Select an optional backend

Choose one when installing:

```bash
./setup.sh --stt-backend=parakeet-mlx
# Alternative:
./setup.sh --stt-backend=bark-mlx
```

The interactive Mac installer also offers these two choices after its STT
question. These flags select speech recognition only; Supertonic continues
to use the public ONNX runtime. The old --mlx flag refers to unavailable
Supertonic MLX TTS and still fails with guidance. Use --onnx for CPU TTS alongside
MLX STT; --cpu conflicts with GPU speech recognition and fails early.

MLX requires native arm64 macOS. Unsupported hosts and unknown selections fail
before environments or services are installed. Use --stt-backend=onnx for the
existing cross-platform CPU/CUDA server.

An isolated side-by-side check with no persistent service registration:

```bash
VOICE_CONFIG_DIR="$HOME/.config/local-voice-mlx-check" \
PARAKEET_PORT=35093 SUPERTONIC_PORT=38766 \
./setup.sh --stt-backend=bark-mlx --check-install --no-integrations --skip-voices
```

Select unused ports. --skip-parakeet skips whichever STT backend was selected.

## Installation and service behavior

The optional runtime has its own environment under VOICE_CONFIG_DIR/mlx-stt.
The installer pins MLX 0.32.4 and MLX Audio revision
f6d5da9626bcdc5be6eccb3e7b79648548dd1b22. Other installed package versions from
the successful native qualification are recorded in
[mlx-optional-versions.json](../benchmarks/results/macos-issue14/mlx-optional-versions.json).

Parakeet downloads the public transcriber-app/parakeet-tdt-0.6b-v3-mlx-8bit
checkpoint at b56210e2fad422736810524963c24b5e2a1985ab. Bark downloads
ConwayResearch/Underdog-Bark-3.0-Pro at
4b5c51e04aa8d16dda9ecdff71bc29f7360149e4 and converts it locally to MLX affine
8-bit weights, group size 64. Source/output weight hashes are verified. Bark's
conversion validates all mapped tensor names/shapes and reloads strictly.
Model attribution and upstream metadata are retained.

Only a fully converted, verified checkpoint is moved into the final directory.
Existing corrupt/incomplete model directories cause an explicit error and are
preserved. Use a fresh VOICE_CONFIG_DIR to isolate a repair. The first Bark
conversion needs additional temporary RAM and disk for the BF16 intermediate;
runtime memory numbers below do not include that one-time conversion.

Each backend has its own retained model folder. One selected model is loaded
per service, on a single inference worker. It remains resident between requests.
Default binding is localhost, default API port is 5093, and the managed launchd
label remains com.opencode.parakeet-stt. Existing unrelated service definitions
are preserved unless --force explicitly replaces the managed definition.
Switching between the two managed MLX options reuses their environment. To
replace an existing managed ONNX definition, or switch back from MLX to ONNX,
review the definition and add --force.

After loading real weights, readiness checks also check that the local weight
files still exist. Setup then performs an actual transcription request and
checks that the reported backend matches the selected backend.

The API accepts /v1/audio/transcriptions, /v1/models, /health and /healthz.
Supported response formats are json, text and verbose_json, including bounded
native word/segment times. The model identifiers are parakeet-mlx8 and
bark-pro-mlx8 respectively. The generic legacy parakeet-tdt-0.6b-v3 name is an
alias for the selected model, so existing talk clients work without changes.

Audio formats are those supported by the installed SoundFile runtime, including
PCM WAV. The server downmixes and resamples to mono 16 kHz, adds 250 ms leading
silence, uses BF16 activations, and transcribes with 30-second overlapping
chunks. The language form field is accepted for compatibility; no language hint
is applied. Uploads are limited to 32 MiB and decoded audio to 600 seconds.
Overlapping requests get HTTP 429 while inference is busy. Invalid model names,
formats, audio and oversized uploads fail explicitly.

## Measured GPU memory

Apple Silicon uses unified memory. These are **MLX GPU allocations**, not
dedicated VRAM capacity, whole-system use, or an extra amount to add to process
RSS. The model load and inference ran in a fresh process per checkpoint.

| Measurement | Bark Pro MLX 8-bit | Parakeet v3 MLX 8-bit |
| --- | ---: | ---: |
| Active GPU allocations after model loading | 0.732 GiB | 0.732 GiB |
| Peak active GPU allocations, 4 s audio | 0.897 GiB | 0.897 GiB |
| Peak active GPU allocations, 30 s audio | 1.137 GiB | 1.137 GiB |
| Peak active GPU allocations, 60 s audio | 1.140 GiB | 1.140 GiB |
| Peak active GPU allocations, 300 s audio | **1.161 GiB** | **1.161 GiB** |
| Highest sampled active + allocator cache | **1.553 GiB** | **1.553 GiB** |
| Process peak RSS, separately reported | 1.030 GiB | 1.030 GiB |

1 GiB = 1,073,741,824 bytes. Both checkpoints have the same architecture, tensor
shapes and quantization layout; matching allocation sizes are expected.

The active-memory high-water mark uses mx.get_peak_memory(), reset before each
duration, with model loading separately recorded. Allocation cache is a distinct
metric; active + cache was sampled every 2 ms and is an estimate, not an exact
reserved-memory high-water mark. It excludes other applications and driver
overhead. The allocator cache was not manually cleared between durations.

The input is a hash-pinned real Argentinian Spanish sample, repeated/truncated
to 4, 30, 60 and 300 seconds. Each duration ran twice, with 30-second chunks,
2-second overlap, 250 ms padding and BF16 activations. This is a bounded memory
stress test, not a new accuracy benchmark or a guarantee for all workloads.

- [Measurement CLI](../benchmarks/measure_mlx_stt_memory.py)
- [Bark raw memory results](../benchmarks/results/macos-issue14/bark-memory.json)
- [Parakeet raw memory results](../benchmarks/results/macos-issue14/parakeet-memory.json)
- [MLX peak-memory API](https://ml-explore.github.io/mlx/build/html/python/_autosummary/mlx.core.get_peak_memory.html)
- [MLX cache-memory API](https://ml-explore.github.io/mlx/build/html/python/_autosummary/mlx.core.get_cache_memory.html)
- [Earlier accuracy/speed comparison](macos-issue14-verification.md)

Reproduce each model in a separate process:

```bash
python benchmarks/measure_mlx_stt_memory.py \
  --model /path/to/local-checkpoint \
  --audio /path/to/mono-16k-speech.wav \
  --output /path/to/memory.json
```

## Native acceptance

Both optional installer selections completed with exit 0. Bark's newly generated
744,018,828-byte checkpoint matched the previously validated SHA-256
b7d005f04532c1c23ed04010a3e7f442d7eac2fd44457823a4c055f30f785366.

Both installed servers transcribed real speech in all three supported formats,
returned word timings within audio duration, rejected unknown models, unsupported
formats, empty/malformed audio and over-limit uploads with the expected status,
and transcribed again after rejected requests.

Installer-generated launchd definitions were tested with separate temporary
labels. Both bootstrap and kickstart -k passed; the service PID changed and
transcription succeeded again after restart. Both test jobs were removed.
The user's existing Bark service on port 5093 was not replaced.

- [Real API acceptance](../benchmarks/results/macos-issue14/optional-mlx-api-acceptance.json)
- [Native launchd/restart acceptance](../benchmarks/results/macos-issue14/optional-mlx-launchd-acceptance.json)

129 relevant regression tests pass, as do shell syntax/static and whitespace
checks. The complete Bark MLX STT + public Supertonic ONNX TTS installer also
passes together on temporary ports 35093/38766. Microphone capture and subjective
listening remain outside these automated checks. Earlier five xAI wrapper test
failures reproduce on unchanged main.
