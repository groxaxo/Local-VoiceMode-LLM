<p align="center">
  <img src="img/banner.png" alt="Local VoiceMode LLM — private, local voice for AI agents" width="100%">
</p>

<h1 align="center">Local VoiceMode LLM</h1>

<p align="center">
  <strong>Give local AI agents a fast, private voice loop without taking VRAM away from the LLM.</strong>
</p>

<p align="center">
  <a href="https://github.com/groxaxo/Local-VoiceMode-LLM/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/groxaxo/Local-VoiceMode-LLM/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="macOS" src="https://img.shields.io/badge/macOS-supported-111827">
  <img alt="Linux" src="https://img.shields.io/badge/Linux-supported-111827">
  <img alt="Windows" src="https://img.shields.io/badge/Windows-supported-111827">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-2563eb">
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="#how-it-works">Architecture</a> ·
  <a href="#supported-agents">Agents</a> ·
  <a href="#configuration">Configuration</a> ·
  <a href="docs/README.md">Documentation</a>
</p>

---

Local VoiceMode LLM is a cross-platform speech layer for coding agents and local LLMs. It combines:

- **Silero VAD** for microphone endpointing
- **Parakeet TDT 0.6B v3** for local speech-to-text
- **Supertonic 3** for local text-to-speech
- A reusable **`talk` skill** for Claude Code, OpenCode, OpenClaw, Hermes Agent, and Codex
- An optional **Ollama voice loop** and browser dashboard

The default speech path is local and CPU-oriented. On Linux with NVIDIA hardware, the installer can optionally use CUDA; remote STT/TTS providers remain opt-in.

## Why this project exists

Running voice on the same GPU as a large language model wastes scarce VRAM and creates avoidable deployment coupling. This project keeps the speech stack separate:

| Stage | Default backend | Port | Default compute |
|---|---|---:|---|
| Voice activity detection | Silero VAD | — | CPU |
| Speech-to-text | Parakeet TDT 0.6B v3, ONNX | `5093` | CPU |
| Text-to-speech | Supertonic 3, ONNX | `8766` | CPU |
| Dashboard | FastAPI + static HTML | `7862` | CPU |

That leaves the accelerator available for Ollama, vLLM, MLX, or another model server.

## Quick start

### macOS or Linux

```bash
git clone https://github.com/groxaxo/Local-VoiceMode-LLM.git
cd Local-VoiceMode-LLM
chmod +x setup.sh
./setup.sh
```

The interactive installer lets you choose the speech backends and agent integrations. For a non-interactive CPU install:

```bash
./setup.sh --cpu
```

The installed Supertonic service listens on `:8766`. Export the endpoint explicitly so direct `tts.sh` invocations and inherited agent shells use the same port:

```bash
export SUPERTONIC_URL=http://127.0.0.1:8766
```

Then verify the stack:

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

Prerequisites:

```powershell
winget install --id Git.Git
winget install --id Python.Python.3.12
winget install --id Gyan.FFmpeg   # recommended playback option
```

Verify the installed services:

```powershell
& "$env:USERPROFILE\.config\opencode\skills\talk\talk.ps1" status
& "$env:USERPROFILE\.config\opencode\skills\talk\talk.ps1" devices
```

See the full platform guide in [`docs/installation.md`](docs/installation.md).

## What the installer creates

| Component | Default location | Startup mechanism |
|---|---|---|
| Voice environment | `~/.config/opencode/tts-venv/` | on demand |
| Parakeet backend | `~/.config/opencode/parakeet-stt/` | launchd / systemd user service / Task Scheduler |
| Supertonic backend | `~/.config/opencode/supertonic-tts/` | launchd / systemd user service / Task Scheduler |
| Canonical talk skill | `~/.config/opencode/skills/talk/` | invoked by the agent |
| TTS wrapper | `~/.config/opencode/tts.sh` | invoked by `talk.sh` |

Re-running the installer is non-destructive by default. Existing service definitions are preserved unless `--force` or `-Force` is used.

## How it works

```text
Microphone
   │
   ▼
Silero VAD ──► PCM WAV ──► Parakeet STT :5093
                                  │
                                  ▼
                        Agent or local LLM
                                  │
                                  ▼
                   TTS dispatcher and fallbacks
                     │         │          │
                     ▼         ▼          ▼
               Supertonic   local opt.   remote opt.
                  :8766
                     │
                     ▼
                 playback ──► next turn
```

The recorder uses fixed-size audio frames, a bounded ring buffer, pre-speech padding, and trailing-silence endpointing. Each completed utterance is normalized, saved as a mono WAV, and posted to the OpenAI-compatible Parakeet transcription endpoint.

During a normal agent conversation:

1. `talk.sh listen` records and prints the first user utterance.
2. The agent produces a concise spoken reply.
3. `talk.sh speak "reply"` synthesizes and plays it.
4. With `TALK_AUTO_LISTEN=1`, the microphone is pre-warmed and opens for the next turn automatically.
5. Empty stdout means the voice session ended; the agent should stop the loop.

The detailed data flow and platform differences are documented in [`docs/architecture.md`](docs/architecture.md).

## Supported agents

The same skill is installed for each selected agent:

| Agent | Skill location |
|---|---|
| Claude Code | `~/.claude/skills/talk/` |
| OpenCode CLI | `~/.config/opencode/skills/talk/` |
| OpenClaw | `~/.openclaw/skills/talk/` |
| Hermes Agent | `~/.hermes/skills/talk/` |
| Codex | `~/.codex/skills/talk/` |

Typical commands:

```bash
talk.sh listen                         # record and transcribe one turn
talk.sh speak "Hello"                 # synthesize; auto-listen when enabled
talk.sh status                         # backend and configuration health
talk.sh devices                        # list devices and selected microphone
talk.sh pick                           # save an interactive microphone choice
talk.sh loop                           # standalone terminal loop
```

For one-way read-aloud without reopening the microphone:

```bash
TALK_AUTO_LISTEN=0 talk.sh speak "Build completed successfully."
```

## Talk to an Ollama model

The recommended integration uses the Ollama HTTP API and does not rebuild Ollama:

```bash
bash integrations/ollama/install.sh
ollama-voice
ollama-voice llama3.2
ollama-voice llama3.2 --text
```

It preserves conversation history, can speak completed sentences while the model is still generating, and filters reasoning blocks from spoken output. See [`integrations/ollama/README.md`](integrations/ollama/README.md).

## Web dashboard

Start the local dashboard:

```bash
cd frontend
bash start.sh
# http://127.0.0.1:7862
```

The dashboard provides:

- Supertonic synthesis testing
- Parakeet microphone and upload transcription
- VAD threshold, padding, silence, and duration controls
- Backend health checks
- Linux/systemd compute toggles

The GPU restart controls are Linux/systemd-specific. TTS and STT testing work wherever the backend URLs are reachable.

## Configuration

Set variables in the shell that launches the agent, or prefix a single command. Start from [`.env.example`](.env.example), but remember that shell scripts do not automatically import an arbitrary `.env` file.

Recommended local baseline:

```bash
export STT_URL=http://127.0.0.1:5093/v1/audio/transcriptions
export STT_MODEL=parakeet-tdt-0.6b-v3
export SUPERTONIC_URL=http://127.0.0.1:8766
export TTS_ENGINE=supertonic
export TTS_QUALITY=normal
export VAD_THRESHOLD=0.5
export VAD_MIN_SILENCE_MS=700
export TALK_IDLE_TIMEOUT_S=300
```

Important variables:

| Variable | Purpose |
|---|---|
| `STT_ENGINE` | `local` or `remote` on the Unix orchestrator |
| `STT_URL` / `STT_MODEL` | Local transcription endpoint and model id |
| `STT_REMOTE_URL` / `STT_API_KEY` | Remote OpenAI-compatible transcription |
| `TTS_ENGINE` | Primary TTS engine |
| `SUPERTONIC_URL` | Supertonic endpoint; installed default is `http://127.0.0.1:8766` |
| `SUPERTONIC_VOICE` | `F1`–`F5` or `M1`–`M5` |
| `TTS_QUALITY` | `normal` for 8 steps or `high` for 20 steps |
| `VAD_THRESHOLD` | Speech sensitivity |
| `VAD_MIN_SILENCE_MS` | Silence required to close a turn |
| `MIC_QUERY` | Microphone name substring |
| `TALK_AUTO_LISTEN` | Reopen the microphone after playback |
| `TALK_BARGE_IN` | Interrupt playback when speech is detected |
| `TALK_STOP_PHRASES` | Pipe-separated spoken session-stop phrases |

Provider-specific variables and exact fallback order are in [`docs/providers.md`](docs/providers.md).

## Local and remote TTS choices

| Engine | Location | Status |
|---|---|---|
| Supertonic 3 | local ONNX, `:8766` | default, installed automatically |
| NeuTTS | local GGUF, `:8020` | optional |
| Inflect Nano | local, `:8030` | optional, English only |
| Qwen3-TTS | local MLX | optional, Apple Silicon-oriented |
| OpenAI-compatible TTS | remote or LAN | optional |
| Inworld | remote | optional, expressive steering |
| xAI | remote | optional fallback |
| Supertonic 2 | local ONNX, `:8880` | optional service; see its integration guide |

Supertonic 2 currently uses the same API shape as Supertonic 3. Until the dispatcher exposes a dedicated alias, select it by pointing the Supertonic engine at port `8880`:

```bash
TTS_ENGINE=supertonic \
SUPERTONIC_URL=http://127.0.0.1:8880 \
talk.sh speak "Hello from Supertonic 2"
```

## Benchmarks

Measured on an Intel Core i7-12700KF, CPU-only, median of five runs:

| Stage | Workload | Measured latency |
|---|---|---:|
| Silero VAD | 32 ms frame | 0.09 ms |
| Parakeet STT | 2.4 s audio | 307 ms |
| Parakeet STT | 13.4 s audio | 729 ms |
| Supertonic 3 | 2.4 s output, 8 steps | 1.39 s |
| Supertonic 3 | 13.4 s output, 8 steps | 5.18 s |

These measurements describe the benchmark machine, not a universal latency guarantee. Reproduce them against your own installed services:

```bash
python benchmarks/run_benchmark.py
```

Additional results are in [`benchmarks/README.md`](benchmarks/README.md) and [`benchmarks/TTS_BACKENDS.md`](benchmarks/TTS_BACKENDS.md).

## Operational limits

- A single microphone cannot distinguish the user from a television, another person, or speaker bleed. Tune `VAD_THRESHOLD` and use headphones when necessary.
- Barge-in needs echo cancellation or careful microphone placement.
- Remote engines send text or audio to the selected provider; the default local path does not.
- The dashboard's service-restart controls assume Linux `systemd --user`.
- Windows currently has a smaller provider surface than the Unix shell implementation.

## Documentation

| Guide | Contents |
|---|---|
| [`docs/README.md`](docs/README.md) | documentation index |
| [`docs/installation.md`](docs/installation.md) | platform setup, flags, services, uninstall |
| [`docs/architecture.md`](docs/architecture.md) | runtime design and data flow |
| [`docs/providers.md`](docs/providers.md) | TTS/STT engines, credentials, fallback policy |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | diagnosis and recovery commands |
| [`skill/SKILL.md`](skill/SKILL.md) | agent-facing talk-loop contract |

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
├── windows/talk.ps1
├── skill/SKILL.md
├── frontend/
├── integrations/
│   ├── ollama/
│   └── supertonic2/
├── docs/
├── benchmarks/
└── tests/
```

## Related projects

- [Parakeet TDT FastAPI OpenAI server](https://github.com/groxaxo/parakeet-tdt-0.6b-v3-fastapi-openai)
- [Supertonic Express 3](https://github.com/groxaxo/supertonic-express-3)
- [Supertonic 3 v2 model assets](https://github.com/groxaxo/supertonic-3-v2)
- [Qwen3-TTS OpenAI FastAPI](https://github.com/groxaxo/Qwen3-TTS-Openai-Fastapi)
- [OpenVoiceApp](https://github.com/groxaxo/OpenVoiceApp)

## License

MIT
