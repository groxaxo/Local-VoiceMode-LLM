# Documentation

This directory contains the operational and technical reference for Local VoiceMode LLM.

## Start here

| Guide | Use it when |
|---|---|
| [Installation](installation.md) | Installing, upgrading, selecting integrations, managing services, or uninstalling |
| [Apple Silicon MLX setup and repair](macos-repair.md) | Installing, validating, benchmarking, or forcing Supertonic MLX/ONNX on a Mac |
| [Troubleshooting](troubleshooting.md) | A microphone, backend, playback path, provider, or service is not working |
| [Providers](providers.md) | Choosing local or remote STT/TTS and understanding fallback behavior |
| [Architecture](architecture.md) | Reviewing the runtime design, data flow, boundaries, ports, and platform differences |
| [Agent skill contract](../skill/SKILL.md) | Integrating the voice loop into Claude Code, OpenCode, OpenClaw, Hermes, or Codex |
| [Ollama integration](../integrations/ollama/README.md) | Talking directly to an Ollama model |
| [Supertonic 2 integration](../integrations/supertonic2/README.md) | Installing the optional Supertonic 2 service |
| [Benchmarks](../benchmarks/README.md) | Reproducing latency and realtime-factor measurements |

## Runtime map

```text
microphone
   │
   ▼
Silero VAD ──► WAV ──► Parakeet STT :5093
                               │
                               ▼
                        agent / local LLM
                               │
                               ▼
                         TTS dispatcher
                               │
                               ▼
                         audio playback
```

Default local services:

| Service | URL | Default runtime |
|---|---|---|
| Parakeet STT | `http://127.0.0.1:5093` | ONNX CPU by default |
| Supertonic 3 TTS | `http://127.0.0.1:8766` | Apple Silicon: MLX first with ONNX fallback; other CPU hosts: ONNX |
| Dashboard | `http://127.0.0.1:7862` | CPU |
| Ollama, when used | `http://127.0.0.1:11434` | User-selected |

## Documentation principles

The project documentation separates three concepts that are easy to confuse:

1. **Installed backend service** — the server process and port.
2. **Orchestrator** — `talk.sh` on Unix or `talk.ps1` on Windows.
3. **Agent skill** — the instructions that tell an AI agent how to use the orchestrator.

A healthy backend does not guarantee that the orchestrator is pointing at the same port. When diagnosing a problem, verify both the service and the effective environment used by the launching shell.

## Recommended local environment

The installer places Supertonic on `:8766`. Export that endpoint in the shell that starts the agent:

```bash
export STT_URL=http://127.0.0.1:5093/v1/audio/transcriptions
export STT_MODEL=parakeet-tdt-0.6b-v3
export SUPERTONIC_URL=http://127.0.0.1:8766
export TTS_ENGINE=supertonic
export TTS_QUALITY=normal
export VAD_THRESHOLD=0.5
export VAD_MIN_SILENCE_MS=700
```

The repository includes [`.env.example`](../.env.example) as a reference. Shell scripts do not automatically source arbitrary `.env` files; export the variables, source the file explicitly, or place the values in the shell/session configuration used to launch the agent.

## Support boundary

The core supported path is:

- local Silero VAD
- local Parakeet ONNX STT
- local Supertonic 3 TTS
  - Apple Silicon: native MLX with verified ONNX CPU fallback
  - Linux/Intel Mac/Windows: ONNX, with optional CUDA where supported
- macOS, Linux, or Windows installation

Optional providers and integrations are maintained as secondary paths. Their availability, authentication, response schemas, and latency can change independently of the local stack.
