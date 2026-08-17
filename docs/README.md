# Documentation

This directory contains the operational and technical reference for Local VoiceMode LLM.

## Start here

| Guide | Use it when |
|---|---|
| [Installation](installation.md) | Installing, upgrading, selecting integrations, managing services, or uninstalling |
| [Windows installer and manager](windows.md) | Installing Windows prerequisites, selecting components, IndexTTS, or managing scheduled services |
| [Apple Silicon MLX setup and repair](macos-repair.md) | Installing, validating, benchmarking, or forcing MLX/ONNX on a Mac |
| [Troubleshooting](troubleshooting.md) | A microphone, backend, playback path, provider, or service is not working |
| [Providers](providers.md) | Choosing local/remote STT or TTS, credentials, and fallback behavior |
| [Mandatory xAI sentence tagging](xai-sentence-tagging.md) | Configuring or auditing the one-valid-tag-per-sentence xAI invariant |
| [Shared AI provider bridge](ai-provider-bridge.md) | Reusing AI Sentence Tagger / AI Voice Studio for verified xAI and Gemini voices |
| [Architecture](architecture.md) | Reviewing runtime design, data flow, boundaries, ports, and platform differences |
| [Agent skill contract](../skill/SKILL.md) | Integrating the voice loop into Claude Code, OpenCode, OpenClaw, Hermes, or Codex |
| [Ollama integration](../integrations/ollama/README.md) | Talking directly to an Ollama model |
| [AI Sentence Tagger integration](../integrations/ai-sentence-tagger/README.md) | Installing and operating the xAI/Google companion bridge |
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
                         talk orchestrator
                         │             │
                         ▼             ▼
                  service/tts.sh     optional TTS_SH bridge
                  safety wrapper             │
                    │       │                 │
                    ▼       ▼                 │
            tts_backends  tagged xAI         │
                    │       │                 │
                    └───────┴────────┬────────┘
                                    ▼
                              audio playback
```

Default local services:

| Service | URL | Default runtime |
|---|---|---|
| Parakeet STT | `http://127.0.0.1:5093` | ONNX CPU by default |
| Supertonic 3 TTS | `http://127.0.0.1:8766` | Apple Silicon: MLX first with ONNX fallback; other hosts: ONNX |
| Dashboard | `http://127.0.0.1:7862` | CPU |
| Ollama, when used | `http://127.0.0.1:11434` | user-selected |
| AI Sentence Tagger / Voice Studio, when used | `http://127.0.0.1:8000` | user-selected companion |

## Routing concepts

The documentation distinguishes five layers:

1. **Backend service** — the STT/TTS server and port.
2. **Safety wrapper** — `service/tts.sh`; owns every direct or fallback xAI request and enforces sentence tags.
3. **Backend dispatcher** — `service/tts_backends.sh`; implements Supertonic, Qwen, NeuTTS, Inflect, OpenAI-compatible, Inworld, and the historical engine orders.
4. **Implementation override** — `TTS_SH`, used by the shared AI provider bridge.
5. **Agent orchestrator/skill** — `talk.sh`, `talk.ps1`, and the instructions an agent follows.

`TTS_ENGINE` selects the requested backend through the wrapper. The wrapper clears `XAI_API_KEY` while running `tts_backends.sh`, so raw text cannot reach its historical xAI fallback. A legitimate xAI attempt returns to `service/tts.sh`, where every sentence is tagged and audited first.

A healthy backend does not prove that the orchestrator is using the same endpoint. Always inspect the effective environment of the process that launches the agent.

## Recommended local environment

```bash
export STT_URL=http://127.0.0.1:5093/v1/audio/transcriptions
export STT_MODEL=parakeet-tdt-0.6b-v3
export SUPERTONIC_URL=http://127.0.0.1:8766
export TTS_ENGINE=supertonic
export TTS_QUALITY=normal
export VAD_THRESHOLD=0.5
export VAD_MIN_SILENCE_MS=700
```

For direct xAI with a local tagging model:

```bash
export TTS_ENGINE=xai
export XAI_API_KEY=replace-me
export TTS_TAG_MODE=auto
export TTS_TAGGER_URL=http://127.0.0.1:12434/v1
export TTS_TAGGER_MODEL=your-local-model
export TTS_TAGGER_API_KEY=not-needed
```

The repository includes [`.env.example`](../.env.example) as a reference. Shell scripts do not automatically source arbitrary `.env` files.

## Support boundary

The core supported path is local Silero VAD, local Parakeet STT, local Supertonic TTS, and the platform-native orchestrator on macOS, Linux, or Windows.

The strict direct-xAI wrapper is implemented on Unix/macOS. The companion bridge also integrates directly with Unix/macOS `talk.sh`. Windows uses a separate PowerShell dispatcher and is not silently claimed to share those Unix routing changes.

Optional providers and integrations are secondary paths. Their authentication, schemas, latency, and availability can change independently. The AI provider bridge avoids duplicating xAI/Gemini contracts by reading catalogs and synthesizing through a versioned companion service.
