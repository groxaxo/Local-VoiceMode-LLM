# OpenCode Voice Service

**Silero VAD-driven voice conversation for OpenCode.** Continuous 16kHz mic capture with automatic endpointing, remote STT (Parakeet), and **xAI TTS by default** (voice **Eve**, same API as [OpenVoiceApp](https://github.com/groxaxo/OpenVoiceApp) `VoiceBridge`). Local **Chatterbox** on `:8765` is optional.

No beeps, no fixed recording windows. Speak — the VAD detects when you're done. After the agent replies, the mic opens again **immediately** so you can keep talking.

## Features

- **Silero VAD** — neural voice activity detection
- **Automatic endpointing** — trailing silence threshold (default 500ms)
- **xAI TTS default** — `POST https://api.x.ai/v1/tts` (`voice_id`, `language: auto`)
- **Chatterbox optional** — `TTS_ENGINE=chatterbox` or fallback if xAI fails
- **Pipelined talk loop** — `speak` ends → mic opens instantly (`TALK_AUTO_LISTEN=1`)
- **OpenCode skill** — `skill("talk")` for Cursor / OpenCode / Claude Code
- **Standalone CLI** — works without the IDE

## Architecture

```
  Mic ──▶ Silero VAD ──▶ WAV ──▶ Parakeet STT (:5092)
                                      │
                                      ▼
                               Agent / OpenCode
                                      │
                                      ▼
                               xAI TTS (default)
                               or Chatterbox (:8765)
                                      │
                                      ▼
                               afplay ──▶ listen again
```

## Prerequisites

- **macOS** (Apple Silicon recommended)
- **Python 3.12** (`uv` or `pyenv`) — created by `setup.sh`
- **xAI API key** — `XAI_API_KEY` (see `.env.example`)
- **STT**: Parakeet at `100.85.200.51:5092` (or set `STT_URL`)
- **Chatterbox** (optional): `mlx-audio` on `localhost:8765` for fallback / `TTS_ENGINE=chatterbox`

## Quick Start

```bash
git clone https://github.com/groxaxo/opencode-voice-service.git
cd opencode-voice-service
chmod +x setup.sh && ./setup.sh

# Configure xAI (required for default TTS)
export XAI_API_KEY=xai-...   # or copy .env.example into voice-bridge/.env

./service/talk.sh status
./service/talk.sh listen                    # first utterance
./service/talk.sh speak "Hello from Eve."   # speaks, then listens for your reply
```

## Usage

### Standalone CLI

```bash
./service/talk.sh listen              # record + transcribe → stdout
./service/talk.sh speak "reply"       # TTS, then auto-listen → stdout = next user text
TALK_AUTO_LISTEN=0 talk.sh speak "…"  # read aloud only, no mic
TTS_ENGINE=chatterbox talk.sh speak "…"  # force local Chatterbox
./service/talk.sh status
./service/talk.sh devices
```

### OpenCode / Cursor talk loop

The agent runs:

1. **Once:** `talk.sh listen` → first user message  
2. **Each turn:** `talk.sh speak '<short reply>'` → plays audio, then records; **stdout = next user message**  
3. Do **not** call `listen` after `speak` (built in). User can talk while the agent prepares the next LLM call.

See `skill/SKILL.md` for full agent rules.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `TTS_ENGINE` | `xai` | `xai` or `chatterbox` |
| `XAI_API_KEY` | (from `.env`) | Bearer token for xAI TTS |
| `XAI_TTS_VOICE` | `eve` | `ara`, `eve`, `leo`, `rex`, `sal` |
| `TTS_ENABLE_CHATTERBOX_FALLBACK` | `1` | Try Chatterbox if xAI fails |
| `TALK_AUTO_LISTEN` | `1` | After `speak`, run `listen` and print user text |
| `TALK_READY_CUE` | `1` | Short tone before listening |
| `VAD_THRESHOLD` | `0.5` | Speech detection sensitivity |
| `VAD_MIN_SILENCE_MS` | `500` | Silence to end turn |
| `MIC_QUERY` | MacBook | Input device substring |
| `STT_URL` | `http://100.85.200.51:5092/...` | Parakeet endpoint |

API key lookup order: `XAI_API_KEY` env → `~/Documents/IOSAPP/voice-bridge/.env` → `~/.hermes/.env` → `~/.config/opencode/.env`

## Install paths (`setup.sh`)

| File | Installed to |
|------|----------------|
| `service/talk.sh` | `~/.config/opencode/skills/talk/talk.sh` |
| `service/vad_recorder.py` | `~/.config/opencode/skills/talk/` |
| `service/tts.sh` | `~/.config/opencode/tts.sh` + skill dir |
| `skill/SKILL.md` | `~/.config/opencode/skills/talk/SKILL.md` |

## Directory structure

```
opencode-voice-service/
├── README.md
├── setup.sh
├── .env.example
├── service/
│   ├── vad_recorder.py
│   ├── talk.sh
│   └── tts.sh
├── skill/
│   └── SKILL.md
├── launchd/
│   └── com.opencode.tts-server.plist   # optional Chatterbox autostart
└── docs/
    └── architecture.md
```

## Related projects

- [OpenVoiceApp](https://github.com/groxaxo/OpenVoiceApp) — iOS app; xAI TTS contract reference  
- [chatterbox-tts-setup](https://github.com/groxaxo/chatterbox-tts-setup) — optional local TTS server  
- [OpenCode](https://opencode.ai)

## License

MIT
