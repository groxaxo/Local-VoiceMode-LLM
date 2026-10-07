# Anonymous Local VoiceMode installation verification

Verified 8 October 2026 (Pacific/Auckland), Linux x86_64, CPU.

The test started with an empty home/config/cache directory, anonymous GitHub clone,
Git credential helpers disabled, no GitHub/Hugging Face tokens, implicit HF tokens
disabled, and fresh Python environments. No existing model assets were copied in.
Installer defects found during the fresh run were corrected, published, and the
same isolated installation resumed. Final tested installer commit:
`dc68aac1395960b9324f68ab85f529c131cdc005`.

Command: `bash setup.sh --cpu --check-install --skip-voices --no-integrations`.
Final installer exit code: **0**. Both STT and TTS live probes passed.
The temporary API processes were stopped after verification; no persistent
launchd/systemd service was registered and no existing voice stack was changed.

Supertonic health returned HTTP 200, ready=true, model=supertonic-3,
backend=cpu, ten voices, sample_rate=44100, and CPUExecutionProvider on all four
loaded sessions. Both /health and /healthz agreed. English, Spanish, different
steps/speeds and synthesis after a server restart passed. All WAV files parse
as PCM16 and contain non-zero frames and non-silent samples.

| Sample | Voice/language | Steps | Speed | WAV bytes | Audio seconds | Generation seconds |
| --- | --- | --- | --- | --- | --- | --- |
| en-normal | F3/en | 8 | 1.05 | 350252 | 3.971 | 2.518 |
| es-quality | M1/es | 12 | 0.85 | 497708 | 5.642 | 3.023 |
| en-fast | F3/en | 8 | 1.5 | 165932 | 1.881 | 1.019 |
| restart | F3/en | 8 | 1.05 | 307244 | 3.483 | 1.663 |

These are short correctness probes on a shared Linux CPU, not a controlled
performance benchmark. The speech checks overlapped with ASR startup.

Parakeet recognized the generated English recording as:

> Hello, this is an anonymous public installation test.

Its health reported CPU with an INT8 encoder. Transcription returned HTTP 200.

Installer fixes: disable ONNX telemetry before initialization; remove obsolete
MLX variable; temporary install verification; CPU PyTorch wheels; remove
CUDA/TensorRT requirements for CPU Parakeet; SOCKS support in both runtimes.

Remaining limitations: Mac connector get_config and system_info returned
MCP -32603 Internal error, so Apple Silicon/launchd were not executed. MLX
is unavailable in this public runtime. Native Windows, CUDA/CoreML, physical
microphone/speaker playback and human listening remain untested. **Keep #14 open
and PR #15 draft.** 94 non-wrapper regression tests pass; five existing xAI
wrapper failures remain and reproduce before this patch.

SDK code is MIT; model assets retain BigScience Open RAIL-M. These recordings
use the public bundled voices and synthetic test sentences. Model weights and
private source are not included.
