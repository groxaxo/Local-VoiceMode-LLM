<p align="center">
  <img src="img/banner.png" alt="Local VoiceMode LLM — private, local voice for AI agents" width="100%">
</p>

<h1 align="center">Local VoiceMode LLM</h1>

<p align="center">
  <strong>Fast, local-first voice conversations for coding agents and local LLMs—without consuming the model's VRAM.</strong>
</p>

<p align="center">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-supported-111827">
  <img alt="Linux" src="https://img.shields.io/badge/Linux-supported-111827">
  <img alt="Windows" src="https://img.shields.io/badge/Windows-supported-111827">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-2563eb">
</p>

Local VoiceMode LLM is a cross-platform speech layer for Claude Code, OpenCode, OpenClaw, Hermes Agent, Codex, Ollama, and other local agents. The default path keeps microphone endpointing, transcription, and synthesis on the host:

| Stage | Default backend | Port | Compute |
|---|---|---:|---|
| Voice activity detection | Silero VAD | — | CPU |
| Speech-to-text | Parakeet TDT 0.6B v3, ONNX | `5093` | CPU by default |
| Text-to-speech | Supertonic 3, ONNX/MLX | `8766` | CPU or Apple Silicon |
| Dashboard | FastAPI + static HTML | `7862` | CPU |

The accelerator remains available for Ollama, vLLM, SGLang, MLX, or another model server.

## Highlights

- Real VAD-driven microphone turns—no simulated transcript or fake playback.
- Local Parakeet transcription through an OpenAI-compatible endpoint.
- Local Supertonic speech by default, with optional Qwen3-TTS, NeuTTS, Inflect, Inworld, OpenAI-compatible, xAI, IndexTTS, and other backends.
- Automatic listen-after-speak, stop phrases, idle termination, device selection, and optional barge-in.
- Shared agent skill for Claude Code, OpenCode, OpenClaw, Hermes, and Codex.
- Optional Ollama conversation loop and browser dashboard.
- Optional **AI Sentence Tagger / AI Voice Studio bridge** for the verified 26-voice xAI and 30-voice Google Gemini catalogs with provider-correct sentence direction.
- Local deterministic validation; GitHub Actions are not required as a release gate.

## Quick start

### macOS or Linux

```bash
git clone https://github.com/groxaxo/Local-VoiceMode-LLM.git
cd Local-VoiceMode-LLM
chmod +x setup.sh
./setup.sh
```

For a non-interactive CPU installation:

```bash
./setup.sh --cpu
```

The managed Supertonic service listens on `:8766`. Export the endpoint in the shell that starts the agent:

```bash
export SUPERTONIC_URL=http://127.0.0.1:8766
export TTS_ENGINE=supertonic
export TTS_QUALITY=normal
```

Verify the installed stack:

```bash
~/.config/opencode/skills/talk/talk.sh status
~/.config/opencode/skills/talk/talk.sh devices
~/.config/opencode/skills/talk/talk.sh listen
```

### Windows PowerShell

```powershell
git clone https://github.com/groxaxo/Local-VoiceMode-LLM.git
cd Local-VoiceMode-LLM
.\setup.ps1
```

Recommended prerequisites:

```powershell
winget install --id Git.Git
winget install --id Python.Python.3.12
winget install --id Microsoft.VCRedist.2015+.x64
winget install --id Gyan.FFmpeg
```

Graphical component selector and service manager:

```powershell
.\windows\VoiceModeManager.ps1
```

Prebuilt Windows launchers are available under [`dist/windows/`](dist/windows/). See [Windows setup](docs/windows.md).

## Conversation protocol

Initial turn:

```bash
transcript="$(talk.sh listen)"
```

Subsequent turns:

```bash
transcript="$(talk.sh speak "Assistant reply")"
```

With `TALK_AUTO_LISTEN=1`, `speak` synthesizes and plays the reply, emits the ready cue, records the next turn, transcribes it, and prints the next transcript to stdout. Empty stdout is the clean session-end signal.

Do not call `listen` again after `speak`; that opens a duplicate recording cycle.

One-way notification:

```bash
TALK_AUTO_LISTEN=0 talk.sh speak "The build completed successfully."
```

## Supported agents

| Agent | Installed skill path |
|---|---|
| Claude Code | `~/.claude/skills/talk/` |
| OpenCode CLI | `~/.config/opencode/skills/talk/` |
| OpenClaw | `~/.openclaw/skills/talk/` |
| Hermes Agent | `~/.hermes/skills/talk/` |
| Codex | `~/.codex/skills/talk/` |

The canonical agent contract is [`skill/SKILL.md`](skill/SKILL.md).

## TTS choices

| Path | Location | Selection |
|---|---|---|
| Supertonic 3 | local ONNX/MLX | `TTS_ENGINE=supertonic` |
| Supertonic 2 service | local ONNX, `:8880` | `TTS_ENGINE=supertonic` plus alternate URL |
| Qwen3-TTS | local MLX service | `TTS_ENGINE=qwen` or `qwen-lazy` |
| NeuTTS | local GGUF service | `TTS_ENGINE=neutts` |
| Inflect Nano | local, English only | `TTS_ENGINE=inflect` |
| OpenAI-compatible TTS | LAN or hosted | `TTS_ENGINE=openai` |
| Inworld | hosted | `TTS_ENGINE=inworld` |
| Direct xAI | hosted | `TTS_ENGINE=xai` |
| IndexTTS | Windows CUDA service | `TTS_ENGINE=indextts` in `talk.ps1` |
| AI Sentence Tagger / Voice Studio | local companion; xAI or Google synthesis | override `TTS_SH` |

Exact Unix fallback order, credentials, and provider limits are in [Providers](docs/providers.md).

## Verified xAI and Google Gemini voices

The optional companion bridge reuses the exact provider implementation from AI Sentence Tagger or AI Voice Studio instead of maintaining a second catalog in shell code.

| Provider | Built-in voices | Default | Direction semantics | Output used by VoiceMode |
|---|---:|---|---|---|
| xAI | 26 | `eve` | fixed 14 inline + 13 wrapping tags | WAV 48 kHz |
| Google Gemini | 30 | `Kore` | 16 common examples plus creative English direction | WAV 24 kHz |

Google's 16 examples are not an exhaustive allowlist. The companion handles canonical voice casing, exact source preservation, lexical tag boundaries, Google Interactions responses, strict base64, and PCM-to-WAV conversion.

Install the bridge:

```bash
bash integrations/ai-sentence-tagger/install.sh
```

Use Google Gemini:

```bash
export TTS_SH="$HOME/.config/opencode/ai-tts-provider/tts-provider.sh"
export AI_TTS_URL=http://127.0.0.1:8000
export AI_TTS_PROVIDER=google
export AI_TTS_VOICE=Kore

~/.config/opencode/skills/talk/talk.sh speak "The deployment completed."
```

Use xAI:

```bash
export TTS_SH="$HOME/.config/opencode/ai-tts-provider/tts-provider.sh"
export AI_TTS_URL=http://127.0.0.1:8000
export AI_TTS_PROVIDER=xai
export AI_TTS_VOICE=eve
```

Setting `TTS_SH` replaces the built-in Unix dispatcher for that process. Unset it to restore the normal local-first fallback graph.

Full guide: [AI provider bridge](integrations/ai-sentence-tagger/README.md).

## How it works

```text
Microphone
   │
   ▼
Silero VAD ──► PCM WAV ──► Parakeet STT :5093
                                  │
                                  ▼
                         Agent / local LLM
                                  │
                                  ▼
                   talk.sh / talk.ps1 orchestrator
                         │                 │
                         ▼                 ▼
                 built-in tts.sh     optional TTS_SH bridge
                         │                 │
                         └───────┬─────────┘
                                 ▼
                              playback
                                 │
                                 ▼
                            next user turn
```

The detailed recorder coordinates, pre-warmed microphone path, barge-in model, platform differences, and service boundaries are documented in [Architecture](docs/architecture.md).

## Configuration

The scripts read the environment of the process that launches them. They do **not** automatically source `.env.example`.

Recommended local baseline:

```bash
export STT_ENGINE=local
export STT_URL=http://127.0.0.1:5093/v1/audio/transcriptions
export STT_MODEL=parakeet-tdt-0.6b-v3
export TTS_ENGINE=supertonic
export SUPERTONIC_URL=http://127.0.0.1:8766
export TTS_QUALITY=normal
export VAD_THRESHOLD=0.5
export VAD_MIN_SILENCE_MS=700
export TALK_IDLE_TIMEOUT_S=300
```

Important settings:

| Variable | Purpose |
|---|---|
| `STT_ENGINE` | Unix STT route: `local` or `remote` |
| `STT_URL` / `STT_MODEL` | Local transcription endpoint and model |
| `STT_REMOTE_URL` / `STT_API_KEY` | Remote OpenAI-compatible transcription |
| `TTS_ENGINE` | Built-in Unix/Windows primary TTS selection |
| `TTS_SH` | Unix implementation override; used by the AI provider bridge |
| `SUPERTONIC_URL` / `SUPERTONIC_VOICE` | Local Supertonic endpoint and voice |
| `TTS_QUALITY` | `normal` for 8 steps or `high` for 20 steps |
| `VAD_THRESHOLD` | Speech sensitivity |
| `VAD_MIN_SILENCE_MS` | Silence required to close a turn |
| `MIC_QUERY` | Input-device name substring |
| `TALK_AUTO_LISTEN` | Reopen/activate the microphone after playback |
| `TALK_BARGE_IN` | Interrupt playback when speech is detected |
| `TALK_STOP_PHRASES` | Pipe-separated spoken session-stop phrases |

Start from [`.env.example`](.env.example) and copy only the variables needed by your launcher or service manager.

## Ollama voice loop

```bash
bash integrations/ollama/install.sh
ollama-voice
ollama-voice llama3.2
```

It preserves conversation history, can speak completed sentences while generation continues, and filters reasoning blocks from spoken output. See [Ollama integration](integrations/ollama/README.md).

## Dashboard

```bash
cd frontend
bash start.sh
# http://127.0.0.1:7862
```

The dashboard tests Supertonic and Parakeet, exposes VAD controls, and reports backend health. Linux service restart controls require `systemd --user`; synthesis and transcription tests work wherever the configured endpoints are reachable.

## Validation

Local checks do not require GitHub Actions:

```bash
python -m compileall -q service frontend tests integrations
python -m pytest -q
bash -n service/talk.sh service/tts.sh
bash -n integrations/ai-sentence-tagger/tts-provider.sh
bash -n integrations/ai-sentence-tagger/install.sh
python -m unittest tests.test_ai_tts_provider -v
```

Physical microphone, speaker, model-download, OS service-manager, and paid-provider checks remain manual release tests.

## Documentation

| Guide | Contents |
|---|---|
| [Documentation index](docs/README.md) | complete guide map |
| [Installation](docs/installation.md) | platform setup, services, upgrades, uninstall |
| [Windows](docs/windows.md) | PowerShell orchestrator, manager, and prerequisites |
| [Architecture](docs/architecture.md) | runtime design and data flow |
| [Providers](docs/providers.md) | engines, credentials, bridge, and fallback policy |
| [AI provider bridge](docs/ai-provider-bridge.md) | shared xAI/Gemini integration architecture |
| [Troubleshooting](docs/troubleshooting.md) | diagnosis and recovery |
| [Benchmarks](benchmarks/README.md) | reproducible latency tests |

## Operational boundaries

- The default VAD/STT/TTS path stays local; remote engines send reply text or recorded audio to the selected endpoint.
- Barge-in is acoustic detection, not echo cancellation. Prefer headphones when speakers bleed into the microphone.
- Windows and Unix orchestrators are separate implementations; do not assume feature parity.
- The AI provider bridge currently integrates directly with Unix/macOS `talk.sh`; its Python client is portable, but the Windows dispatcher is not automatically redirected.
- A companion AI Sentence Tagger/Voice Studio request is stateless and does not create persistent Studio projects.
- Never commit API credentials or include them in prompts and logs.

## Project layout

```text
Local-VoiceMode-LLM/
├── setup.sh / setup.ps1
├── service/
│   ├── talk.sh
│   ├── tts.sh
│   ├── tts_lang.sh
│   ├── inworld_steer.sh
│   └── vad_recorder.py
├── windows/
│   ├── talk.ps1
│   └── VoiceModeManager.ps1
├── integrations/
│   ├── ai-sentence-tagger/
│   ├── ollama/
│   └── supertonic2/
├── skill/SKILL.md
├── frontend/
├── docs/
├── benchmarks/
└── tests/
```

## License

MIT
