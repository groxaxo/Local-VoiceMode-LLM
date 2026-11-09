# Issue #14: native Mac verification and Bark comparison

Tested 10 November 2026 (Pacific/Auckland) on a MacBook Air M5, 24 GB unified
memory, macOS 27.0.1, Apple arm64. Base: main at 4b3f6ef.

## Result

The original missing/private Supertonic repository dependency was replaced in
PR #15. The public pinned runtime now installs and produces real speech on this
Mac. This follow-up prevents misleading verification, records native evidence,
and adds a repeatable MLX STT comparison.

- STT readiness always POSTs an actual WAV to /v1/audio/transcriptions.
  A healthy /health endpoint cannot mask a missing model or broken inference.
  Empty string output is valid for the silence probe; malformed JSON and
  non-string text are failures.
- --check-install rejects occupied, duplicate and invalid selected service ports
  before dependency installation. Its temporary Parakeet server binds localhost.
  --venv-only does not require service ports.
- Python selection checks >=3.11 before creating a virtual environment. Apple's
  system Python 3.9 is not silently selected.
- Existing user checkouts, services and agent integrations were preserved.
  All verification and tests ran locally; GitHub Actions was not used.

## Native installation

A separate checkout and a new VOICE_CONFIG_DIR were used. The first attempt
installed dependencies and models, then exposed a real port collision on 18766.
The new preflight prevents that failure from progressing into installation or
probing an unrelated server.

The fixed installer completed with exit 0:

```bash
VOICE_CONFIG_DIR="$HOME/voice-issue14-validation" \
PARAKEET_PORT=25093 SUPERTONIC_PORT=28766 \
./setup.sh --check-install --no-integrations --skip-voices
```

The run began with fresh environments and no preinstalled runtime at that
configuration path. After the collision fix it reused its downloaded
dependencies/assets. This was not a clean-HOME anonymous-install qualification.

Public Supertonic SDK pin:
df0f9686dac7fbbde391b759e2ee5286a3737622.
Model: Supertone/supertonic-3 at
724fb5abbf5502583fb520898d45929e62f02c0b.

The adapter reported ready=true, model=supertonic-3, backend=cpu, ten voices,
44,100 Hz audio and CPUExecutionProvider for all four ONNX sessions.

## Real synthesis, transcription and restart

See [raw acceptance JSON](../benchmarks/results/macos-issue14/voice-api-acceptance.json).

| Test | Result |
| --- | --- |
| English, F3, 8 steps, speed 1.0 | 236,544 non-silent PCM frames, 5.364 s |
| Spanish, F3, 12 steps, speed 1.0 | 301,056 non-silent PCM frames, 6.827 s |
| English, speed 0.8 / 1.25 | 6.757 s / 4.319 s |
| Generated English and Spanish -> installed Parakeet ONNX | Both exact prompt transcriptions, including punctuation |
| Invalid voice / conflicting language fields / streaming | HTTP 400 / 422 / 400 |
| TTS process restart | Health and new synthesis passed |
| Installer-generated launchd plist | plutil validation and real bootstrap passed |
| launchctl kickstart -k | New health and speech requests passed |
| Test launchd cleanup | bootout exit 0; no test job left registered |

For launchd verification the installer generated the real plist into an isolated
directory. Its label was changed to com.local-voicemode.issue14-validation;
bootstrap and kickstart exercised that job without replacing production labels.
The already installed environment was reused, with package-install functions
stubbed only during this second plist-generation check. Actual SDK preparation
and plist generation still ran.
[Launchd evidence](../benchmarks/results/macos-issue14/launchd-acceptance.json).

No microphone recording, subjective listening or interactive agent conversation
was performed. WAV validation plus exact round-trip transcription provide the
automated evidence. Leave #14 open for reporter confirmation/listening rather
than claiming all release-gate items have been completed. Supertonic MLX,
CoreML, CUDA and Windows are outside this Mac CPU validation.

## Bark Pro MLX 8-bit versus Parakeet v3 MLX 8-bit

The existing Mac service on port 5093 was already configured for Bark Pro,
not the unrelated Suno Bark TTS or Bark Plus model.

Both configured MLX checkpoints had lost their weight files while retaining
configuration/tokenizer files. The service still returned a health response.
The pinned Bark source was downloaded and hash checked, then reconverted using
the existing conversion workflow. The resulting 744,018,828-byte 8-bit file
matched its previous SHA-256:
b7d005f04532c1c23ed04010a3e7f442d7eac2fd44457823a4c055f30f785366.
The pinned Parakeet checkpoint was restored too. The existing service was then
tested through /v1/audio/transcriptions with both model selectors; both returned
nonempty transcripts and bounded native word timings. Existing binding,
default model and port 5093 were retained.

Fresh runs used the same hashed mono 16 kHz audio, 250 ms leading silence,
BF16 activations, no language hints and strict offline local model loading.
Each checkpoint ran in its own process with one warmup and two measured
inferences per clip. Repeated transcripts were deterministic.

| Corpus | Clips | Bark WER | Parakeet WER | Bark warm time | Parakeet warm time |
| --- | ---: | ---: | ---: | ---: | ---: |
| Real Argentinian Spanish | 100 | 4.22% (38/901) | 4.00% (36/901) | 5.057 s | 4.864 s |
| Synthetic English | 16 | 1.50% (6/400) | 1.50% (6/400) | 1.285 s | 1.302 s |
| Synthetic Spanish | 16 | 2.82% (12/426) | 2.82% (12/426) | 1.410 s | 1.425 s |

The real corpus contains 488.704 seconds of audio: approximately 96.6x realtime
for Bark and 100.5x for Parakeet, excluding model load, Python startup, HTTP and
audio decoding. Load times were 1.281 s and 1.378 s respectively. Peak MLX
allocations were about 1.021 GB for both; these are not whole-system memory.

Primary WER keeps accents. Accent-folded real Spanish WER was 2.44% for both.
There is no convincing general accuracy or speed winner here: Parakeet made
two fewer word errors on this small real subset, while the synthetic primary
scores tied. Preserve the existing Bark default; these results do not justify
switching it for accuracy.

Real corpus: first 50 female/train and first 50 male/train rows of
ylacombe/google-argentinian-spanish, revision
a7e9786e3930b57ae95d38859106e4b50444f943. References are retained upstream text.
Synthetic corpus: eight English and eight Spanish prompts spoken with two
Supertonic voices. Synthetic references are synthesis prompts, not independent
human transcripts. Neither corpus establishes performance on noisy speech,
other accents, long recordings or the user's microphone.

### Reproduction and evidence

- [Benchmark CLI](../benchmarks/compare_mlx_stt.py)
- [Manifest with audio hashes](../benchmarks/results/macos-issue14/manifest.json)
- [Bark per-clip predictions, versions and hashes](../benchmarks/results/macos-issue14/bark-pro-8bit.json)
- [Parakeet per-clip predictions, versions and hashes](../benchmarks/results/macos-issue14/parakeet-v3-8bit.json)
- [Live API responses](../benchmarks/results/macos-issue14/mlx-api-acceptance.json)

The manifest points at retained local corpus audio; weights and recordings are
not committed. To reproduce elsewhere, obtain the pinned corpus/checkpoints,
update only audio paths, and retain/verify the manifest's audio hashes.

```bash
python benchmarks/compare_mlx_stt.py \
  --manifest /path/to/manifest.json \
  --model /path/to/local-checkpoint \
  --output /path/to/results.json --repeats 2
```

Run each model separately in an Apple Silicon environment with mlx-audio,
soundfile, jiwer and num2words. Exact installed versions and model weight hashes
are recorded in both result files.

## Regression checks

106 tests pass when excluding tests/test_tts_wrapper.py. Shell static checks
and git diff --check pass. The five xAI wrapper tests fail identically in a
separate untouched worktree at 4b3f6ef; none of those files changed here.
The Mac system python3 is 3.9, so tests were run with the installed Python 3.12
environment. No cloud API synthesis requests were used for those tests.
