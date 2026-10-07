# Public Supertonic runtime and issue #14

Fresh installs use `supertone-oss-archive/supertonic-py` at
`df0f9686dac7fbbde391b759e2ee5286a3737622` (SDK 1.3.1), plus this repository's
small `service/supertonic_server.py` adapter. No private source is included,
published, or made accessible. The previous private runtime is not a dependency.

## Candidate evaluation

| Requirement | ARahim3/supertonic-server @ 8707a3ad | Supertone archived SDK @ df0f9686 |
| --- | --- | --- |
| Speech | `/v1/audio/speech`, input/voice/speed/total_steps/lang | Speech server exists, but OpenAI schema omits total_steps; SDK accepts it |
| Health | `/healthz`; different response shape | `/v1/health`; lacks backend reporting |
| Assets | SDK download, Supertonic 3, F1-F5/M1-M5 | Official pinned Supertonic 3 download, same ten voices |
| Apple Silicon | ONNX CoreML selection with CPU fallback | ONNX CPU default; no MLX |
| License evidence | MIT declared in pyproject; no standalone LICENSE in inspected snapshot | Full MIT LICENSE supplied |
| Layout | src package, CLI, streaming/UI dependencies, Python >=3.11 | Root package, Python >=3.9, smaller dependency surface |

Choose the archived SDK with a narrow adapter: it avoids the larger alternative's
UI/streaming dependencies and preserves the required synthesis controls. The
archive receives no upstream maintenance; updates require explicit review.

The adapter implements buffered WAV only. It maps both `lang` and legacy
`lang_code` into the SDK's `lang`; conflicts fail. `model`, `input`, `voice`,
`speed`, `total_steps`, `response_format=wav`, and `stream=false` are validated.
Unknown voices/languages and unsupported formats fail before inference.
It serializes inference and rejects empty/non-finite audio. `/health` and
`/healthz` report readiness, model, sample rate, voice count and provider lists
from all four instantiated ONNX sessions. Provider registration does not prove
per-node GPU utilization; no performance claim is made.

## Assets and license

The SDK downloads `Supertone/supertonic-3` at
`724fb5abbf5502583fb520898d45929e62f02c0b`, preserving the model repository's
LICENSE and model card. Required layout is `onnx/` (four model modules, `tts.json`,
`unicode_indexer.json`) plus `voice_styles/` with F1-F5/M1-M5. Preparation loads
all sessions and all ten styles before writing service definitions.

SDK code is MIT, copyright Supertone Inc. Model assets are **BigScience Open
RAIL-M**, not MIT; use and redistribution must comply with the pinned model
license, including its use restrictions and required notices. Model weights are
not checked into this repository. Read the [model license](https://huggingface.co/Supertone/supertonic-3/blob/724fb5abbf5502583fb520898d45929e62f02c0b/LICENSE)
and [SDK license](https://github.com/supertone-oss-archive/supertonic-py/blob/df0f9686dac7fbbde391b759e2ee5286a3737622/LICENSE).

## Installation and migration

Apple Silicon defaults to public ONNX CPU. `--onnx`/`--cpu` select CPU; `--mlx`
fails explicitly before installation. Neither candidate supplies the private
MLX implementation. Native macOS, launchd, CoreML, MLX, and CUDA speech are not
validated by Linux contract tests. CUDA is opt-in and fails if its provider is
unavailable; hardware performance must be tested separately.

Existing checkout remotes are preserved. A different runtime or non-Git
Supertonic directory fails with guidance, including with `--force`; no existing
runtime is deleted. Tracked local edits also stop installation. Re-running the
same public installation selects the pin without pulling upstream HEAD.
`SUPERTONIC_REPO_URL` can select a trusted mirror containing that exact commit;
it is not an arbitrary API-compatible runtime selector.

For an isolated fresh Unix install, preserving the old directory:

```bash
VOICE_CONFIG_DIR="$HOME/.config/local-voicemode-public" ./setup.sh --onnx --skip-voices --no-integrations
```

The installer still manages the usual service labels, so test alongside an
existing stack only after reviewing those labels/ports. Windows uses the same
pin and adapter on CPU; its PowerShell changes require native validation.

## Release gate

**Keep #14 open.** Before declaring the macOS install repaired, perform an
anonymous fresh install on Apple Silicon, check `/health` for HTTP 200,
`ready=true`, `model=supertonic-3`, `backend=cpu`, ten voices, and all four provider
lists, then POST `/v1/audio/speech`. Verify a parseable WAV with non-zero frames
and non-silent samples; listen to it. Test English and Spanish, speed, steps,
and a restart. Package/import success and synthetic-engine tests do not satisfy
this gate. MLX remains unavailable; do not claim it was validated.

## Validation on 8 October 2026 (Auckland)

The anonymous Linux installation now passes with exit code 0. Real English and
Spanish synthesis, expected /health and /healthz results, synthesis after server
restart, and generated-speech transcription all pass. The test started from an
empty isolated home and fresh environments; installer issues found during the
run were fixed and published, and installation resumed without importing
existing model assets. See [the verification report](anonymous-install-verification.md)
for exact source commit, methodology, WAV metrics and remaining limitations.

The earlier telemetry rejection was addressed using ONNX Runtime's documented
`ORT_DISABLE_TELEMETRY=1` process-wide opt-out before any runtime import, plus
API event suppression. Both the installed runtime binary and official upstream
privacy documentation support the environment opt-out. No telemetry destination
was authorized or bypassed.

`--check-install` starts temporary localhost API processes, runs the installer
probes, and stops them on exit, without registering persistent services. It still
installs the selected stack and skill files into VOICE_CONFIG_DIR. Use isolated
HOME/config/cache paths, unused ports and `--no-integrations` for a bounded test.

94 non-wrapper regression tests pass, as do shell/static, plist and whitespace
checks. Five existing xAI-wrapper failures remain; the unchanged earlier tts.sh
reproduces them. Native macOS/launchd, Windows, CUDA/CoreML/MLX, physical audio
capture/playback and human listening remain untested. Keep #14 open and PR #15
draft until the Apple Silicon release gate passes.

```bash
python -m pytest -q
bash tests/test_setup_static.sh
git diff --check
```

The full pytest command reports the existing xAI-wrapper failures. No GitHub
Actions are used.
