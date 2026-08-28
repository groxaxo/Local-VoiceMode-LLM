# Ollama voice integration

Talk to an Ollama model through the Local VoiceMode LLM speech stack:

```text
microphone → Silero VAD → Parakeet STT → Ollama chat → Supertonic TTS → speakers
```

The default speech stages run locally on CPU, leaving the GPU available for Ollama's model.

## Choose an integration

| | Recommended: `ollama-voice` command | Advanced: native `ollama voice` patch |
|---|---|---|
| Existing Ollama install | reused as-is | replaced by a custom source build |
| Setup | one installer | apply patch and compile Ollama |
| Chat transport | Ollama HTTP API on `:11434` | in-process Ollama client |
| Command | `ollama-voice <model>` | `ollama voice <model>` |
| Best use | normal installations | custom Ollama distributions and development |

Most users should use the standalone `ollama-voice` command.

## Standalone `ollama-voice` command

### Requirements

- An installed and working Ollama CLI/server
- Bash
- Python 3
- curl
- A supported audio player
- A microphone for voice input; `--text` can be used without one

Verify Ollama first:

```bash
ollama --version
ollama list
```

### Install

From the Local VoiceMode LLM repository root:

```bash
bash integrations/ollama/install.sh
```

Non-interactive setup:

```bash
bash integrations/ollama/install.sh --yes
```

The installer:

1. Verifies the existing Ollama installation.
2. Installs or repairs the Local VoiceMode LLM speech backends unless skipped.
3. Installs `ollama-voice` into a user executable directory, normally `~/.local/bin`.
4. Checks Ollama, Parakeet, and the selected local TTS endpoint.

It does not rebuild Ollama or edit its source tree.

### Installer options

Run the installer with `--help` for the current complete list. Common options include:

| Option | Effect |
|---|---|
| `--yes` | Run non-interactively |
| `--bindir DIR` | Install the command in a specific directory |
| `--model NAME` | Ensure an Ollama model is available |
| `--skip-backends` | Install only the command |
| `--reinstall-backends` | Rerun backend setup |
| `--uninstall` | Remove the command |
| `--uninstall --backends` | Also remove managed speech backends |

### Use

```bash
ollama-voice                     # default/first installed model
ollama-voice llama3.2            # explicit model
ollama-voice llama3.2 --text     # keyboard input; replies remain spoken
ollama-voice llama3.2 --once     # one exchange and exit
ollama-voice --list              # list local models
ollama-voice --status            # check Ollama and speech services
ollama-voice --setup             # install or repair the integration
```

Use `Ctrl+C` to stop. The runtime also recognizes configured voice-exit phrases.

### Runtime flow

```text
ollama-voice
   │
   ├── talk.sh listen
   │     └── VAD → WAV → Parakeet → transcript
   │
   ├── POST /api/chat to Ollama
   │     └── streamed assistant response
   │
   ├── filter reasoning/code from spoken stream
   │
   └── talk.sh speak
         └── selected TTS → playback → next listen
```

The command maintains bounded conversation history and uses Ollama's streaming chat API. Reasoning sections such as `<think>...</think>` are not sent to TTS.

### Sentence-streamed TTS

Sentence-level TTS is enabled by default. As Ollama streams text, complete natural-language sentences are queued for speech while generation continues.

```text
Ollama tokens ─► sentence 1 ─► TTS/playback
             └► sentence 2 ─► TTS/playback
             └► sentence 3 ─► TTS/playback
```

This reduces time to first audio but can produce more TTS requests. Disable it when the selected provider charges per request, handles long text more naturally, or needs one complete utterance:

```bash
ollama-voice llama3.2 --no-stream-tts
```

Equivalent environment:

```bash
export OLLAMA_VOICE_STREAM_TTS=0
```

### Configuration

| Variable | Typical/default behavior | Purpose |
|---|---|---|
| `OLLAMA_HOST` | `http://127.0.0.1:11434` | Ollama API base URL |
| `OLLAMA_VOICE_MODEL` | first available model when unset | default model |
| `OLLAMA_VOICE_THINK` | `false` | Ollama reasoning mode; reasoning is never spoken |
| `OLLAMA_VOICE_SYSTEM` | concise spoken-answer prompt | system instruction |
| `OLLAMA_VOICE_LANG` | auto | TTS language hint |
| `OLLAMA_VOICE_STREAM_TTS` | `1` | speak completed sentences during generation |
| `OLLAMA_VOICE_KEEPALIVE` | Ollama default | model keep-alive value |
| `OLLAMA_VOICE_NUM_PREDICT` | `400` | maximum generated tokens; `0` removes the cap |
| `OLLAMA_VOICE_HISTORY` | `20` | retained conversation messages; `0` keeps all |
| `OLLAMA_VOICE_NO_DETECT` | unset | set `1` to disable local TTS endpoint probing |
| `TALK_SH` | installed skill path | explicit orchestrator path |
| `OLLAMA_VOICE_ENV` | `~/.config/opencode/ollama-voice.env` | defaults and endpoint-detection cache |

The normal Local VoiceMode LLM variables are also forwarded, including:

```text
STT_URL
STT_MODEL
TTS_ENGINE
SUPERTONIC_URL
SUPERTONIC_VOICE
TTS_QUALITY
VAD_THRESHOLD
VAD_MIN_SILENCE_MS
MIC_QUERY
TALK_IDLE_TIMEOUT_S
```

Recommended managed-backend baseline:

```bash
export STT_URL=http://127.0.0.1:5093/v1/audio/transcriptions
export STT_MODEL=parakeet-tdt-0.6b-v3
export TTS_ENGINE=supertonic
export SUPERTONIC_URL=http://127.0.0.1:8766
export TTS_QUALITY=normal
export VAD_THRESHOLD=0.5
export VAD_MIN_SILENCE_MS=700
```

### TTS endpoint detection

The standalone integration can probe common local Supertonic endpoints and cache a working selection. Explicit `SUPERTONIC_URL` remains the most predictable configuration.

Managed Supertonic 3:

```bash
export TTS_ENGINE=supertonic
export SUPERTONIC_URL=http://127.0.0.1:8766
```

Optional Supertonic 2 service:

```bash
bash integrations/supertonic2/install.sh
export TTS_ENGINE=supertonic
export SUPERTONIC_URL=http://127.0.0.1:8880
```

The core dispatcher currently has no separate `supertonic2` engine value. It uses the normal Supertonic-compatible client with the alternate URL.

To bypass probing and trust the configured endpoint:

```bash
export OLLAMA_VOICE_NO_DETECT=1
```

### Text-only input test

This isolates Ollama and TTS from microphone/VAD problems:

```bash
ollama-voice llama3.2 --text --once
```

When this succeeds but voice input fails, diagnose microphone permissions, device selection, and VAD rather than the Ollama API.

### Status and diagnosis

```bash
ollama-voice --status
curl -fsS http://127.0.0.1:11434/api/tags
~/.config/opencode/skills/talk/talk.sh status
~/.config/opencode/skills/talk/talk.sh devices
```

See [`../../docs/troubleshooting.md`](../../docs/troubleshooting.md) for backend and microphone recovery.

### Uninstall

```bash
bash integrations/ollama/install.sh --uninstall
bash integrations/ollama/install.sh --uninstall --backends
```

The first command removes the `ollama-voice` command. The second also removes managed speech services according to the installer behavior.

## Files

| File | Purpose |
|---|---|
| `install.sh` | standalone command/backend installer |
| `ollama-voice` | Python runtime using Ollama's HTTP API |
| `0001-ollama-voice.patch` | optional native Ollama source patch |

## Advanced native `ollama voice` patch

The included patch adds voice functionality directly to an Ollama source checkout. Use this path only when maintaining a custom Ollama binary.

### Requirements

- A compatible Go toolchain for the targeted Ollama revision
- Ollama's native build dependencies
- Git
- Python and the speech backend requirements

Ollama's development requirements change over time. Follow the version-specific build documentation in the Ollama checkout rather than relying on a permanently fixed Go version in this repository.

### Apply

```bash
git clone https://github.com/ollama/ollama.git
cd ollama

git am /path/to/Local-VoiceMode-LLM/integrations/ollama/0001-ollama-voice.patch
# or, without preserving commit metadata:
git apply /path/to/Local-VoiceMode-LLM/integrations/ollama/0001-ollama-voice.patch
```

A patch is revision-sensitive. If it does not apply cleanly, inspect upstream changes and port it deliberately; do not force-apply rejected hunks.

### Build

Use the build procedure documented by the checked-out Ollama revision. A simple development build may be:

```bash
go build .
```

The full native build can require additional steps and platform toolchains.

### Setup and use

After building the patched binary:

```bash
./ollama voice --setup
./ollama voice llama3.2
```

The patch may also add a `/voice` command inside an interactive `ollama run` session, depending on the upstream revision it targets.

### Maintenance warning

The native patch embeds or coordinates speech scripts separately from the standalone installation. Treat the two paths as distinct products:

- The standalone `ollama-voice` command follows this repository's current scripts.
- The patch reflects the Ollama source revision against which it was authored.

For long-term reliability, prefer the standalone HTTP integration unless a custom Ollama binary is an explicit requirement.
