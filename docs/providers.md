# Speech providers and fallback policy

Local VoiceMode LLM is designed around a local speech path:

- Silero VAD on the host
- Parakeet STT on `127.0.0.1:5093`
- Supertonic TTS on `127.0.0.1:8766`

Remote providers are optional. Use them when a machine is too slow for local synthesis, when a specific hosted voice is required, or when the speech service runs on another machine on the LAN.

## Choose a deployment pattern

| Situation | STT recommendation | TTS recommendation |
|---|---|---|
| Modern desktop or laptop | local Parakeet | local Supertonic |
| GPU is reserved for the LLM | local Parakeet on CPU | local Supertonic on CPU |
| Old or heavily loaded CPU | keep Parakeet local first | remote OpenAI-compatible TTS |
| Air-gapped or privacy-sensitive system | local only | local only |
| Expressive hosted voice is required | local Parakeet | Inworld or another selected provider |
| Speech runs on another LAN host | OpenAI-compatible remote STT URL | OpenAI-compatible TTS URL |

Parakeet transcription is normally the lighter stage. Offload TTS first when conversational latency is the problem.

## Environment loading

The scripts read environment variables from the process that launches them. They do not automatically load the repository's `.env.example` or an arbitrary `.env` file.

Recommended local baseline:

```bash
export STT_ENGINE=local
export STT_URL=http://127.0.0.1:5093/v1/audio/transcriptions
export STT_MODEL=parakeet-tdt-0.6b-v3

export TTS_ENGINE=supertonic
export SUPERTONIC_URL=http://127.0.0.1:8766
export TTS_QUALITY=normal
```

The explicit `SUPERTONIC_URL` matters because the managed installer uses port `8766`, while older/manual layouts may use `8765`.

## Local TTS engines

### Supertonic 3

Supertonic 3 is the supported default backend installed by `setup.sh` and `setup.ps1`.

```bash
export TTS_ENGINE=supertonic
export SUPERTONIC_URL=http://127.0.0.1:8766
export SUPERTONIC_VOICE=F4
export TTS_QUALITY=normal
```

| Variable | Recommended/default behavior | Purpose |
|---|---|---|
| `SUPERTONIC_URL` | set explicitly to `http://127.0.0.1:8766` for the managed install | API base URL |
| `SUPERTONIC_VOICE` | `F4` | `F1`–`F5` or `M1`–`M5` |
| `TTS_QUALITY` | recommended `normal`; the current low-level script falls back to `high` when unset | `normal` = 8 steps, `high` = 20 steps |
| `SUPERTONIC_STEPS` | derived from quality | explicit step override from 1–20 |
| `SUPERTONIC_SPEED` | `1.0` | synthesis speed multiplier |
| `TTS_FADE_MS` | `6` | edge fade used to reduce clicks |

For low-latency conversation, set `TTS_QUALITY=normal` explicitly.

### Supertonic 2 service

The optional installer creates a second OpenAI-compatible Supertonic service on `:8880`:

```bash
bash integrations/supertonic2/install.sh
```

The current TTS dispatcher does **not** expose a dedicated `supertonic2` engine alias. Select the compatible service by retaining the `supertonic` engine and changing its URL:

```bash
TTS_ENGINE=supertonic \
SUPERTONIC_URL=http://127.0.0.1:8880 \
talk.sh speak "Hello from Supertonic two"
```

This gives direct access to the service. It does not automatically fall back to the Supertonic 3 URL if `:8880` is unavailable; change the URL back to `:8766` or use your own wrapper/proxy for multi-endpoint failover.

### NeuTTS

NeuTTS is an optional local GGUF service:

```bash
export TTS_ENGINE=neutts
export NEUTTS_URL=http://127.0.0.1:8020
```

Language-specific model variables are available for English, Spanish, German, and French:

- `NEUTTS_MODEL`
- `NEUTTS_MODEL_ES`
- `NEUTTS_MODEL_DE`
- `NEUTTS_MODEL_FR`

The backend is not installed by the main setup scripts.

### Inflect Nano

Inflect Nano is an optional, experimental English-only endpoint:

```bash
export TTS_ENGINE=inflect
export INFLECT_URL=http://127.0.0.1:8030
```

For non-English text it declines the request so the configured fallback chain can continue.

### Qwen3-TTS

Qwen3-TTS is an optional local MLX/OpenAI-compatible backend, primarily for Apple Silicon. Install and operate it separately through the Qwen3-TTS server project.

```bash
export TTS_ENGINE=qwen
export QWEN_TTS_QUALITY=hq
export QWEN_TTS_VOICE=vivian
```

| Quality | Default URL | Intended use |
|---|---|---|
| `fast` | `http://127.0.0.1:18881` | lower-latency 0.6B server |
| `hq` | `http://127.0.0.1:18882` | always-on 1.7B server |
| `lazy` | `http://127.0.0.1:18883` | 1.7B server started on demand |

Override `QWEN_TTS_URL` to bypass quality-based URL selection.

## Remote OpenAI-compatible TTS

The `openai` engine sends the standard speech payload to:

```text
<OPENAI_TTS_URL>/audio/speech
```

It can target OpenAI or another compatible service, including a server on the local network.

```bash
export TTS_ENGINE=openai
export OPENAI_TTS_URL=https://api.openai.com/v1
export OPENAI_TTS_KEY=...
export OPENAI_TTS_MODEL=gpt-4o-mini-tts
export OPENAI_TTS_VOICE=alloy
export OPENAI_TTS_FORMAT=wav
```

`OPENAI_API_KEY` is used when `OPENAI_TTS_KEY` is not set.

| Variable | Low-level default | Purpose |
|---|---|---|
| `OPENAI_TTS_URL` | `https://api.openai.com/v1` | API base URL, without `/audio/speech` |
| `OPENAI_TTS_KEY` | value of `OPENAI_API_KEY` | bearer token |
| `OPENAI_TTS_MODEL` | `gpt-4o-mini-tts` | provider model id |
| `OPENAI_TTS_VOICE` | `alloy` | provider voice id |
| `OPENAI_TTS_FORMAT` | `wav` | requested output format |

For normal playback, replies are split at sentence boundaries, requests are issued in parallel, and audio is played in order as chunks become ready. With `TTS_NO_PLAY=1`, the implementation uses a single request so it can return one file path to the orchestrator.

Provider compatibility is not guaranteed merely because an API is described as OpenAI-compatible. Confirm that it accepts the same field names and returns the requested audio format.

## Inworld TTS

Inworld is an optional hosted engine with per-sentence expressive steering.

```bash
export TTS_ENGINE=inworld
export INWORLD_API_KEY=...
export INWORLD_TTS_VOICE=Ashley
export INWORLD_TTS_MODEL=inworld-tts-2
export INWORLD_STEER=auto
```

| Variable | Low-level default | Purpose |
|---|---|---|
| `INWORLD_API_KEY` | required | Basic/base64 API credential; `INWORLD_TTS_API` is also read |
| `INWORLD_TTS_VOICE` | `Ashley` | provider voice id |
| `INWORLD_TTS_MODEL` | `inworld-tts-2` | model id |
| `INWORLD_TTS_URL` | Inworld voice endpoint | request URL |
| `INWORLD_STEER` | `auto` | enable/disable delivery-tag generation |
| `INWORLD_STEER_PERSONA` | empty | optional persona hint |
| `INWORLD_TTS_ENCODING` | `LINEAR16` | returned audio encoding |
| `INWORLD_TTS_SAMPLE_RATE` | `48000` | sample rate used for WAV wrapping |

Steering improves expressiveness but adds another model call before synthesis. Set `INWORLD_STEER=0` when time-to-first-audio is more important.

HTTP `401` and `403` are treated as credential/configuration failures. The Unix dispatcher intentionally exits loudly instead of silently switching to another voice.

## xAI TTS

xAI is an optional hosted engine and the final cloud fallback in several local-primary chains.

```bash
export TTS_ENGINE=xai
export XAI_API_KEY=...
export XAI_TTS_VOICE=eve
```

The current script sends requests to the configured xAI TTS API path and supports the voice ids used by that provider integration. Hosted APIs can change; verify current provider access and schemas when diagnosing failures.

## Speech-to-text providers

### Local Parakeet

```bash
export STT_ENGINE=local
export STT_URL=http://127.0.0.1:5093/v1/audio/transcriptions
export STT_MODEL=parakeet-tdt-0.6b-v3
```

The request is multipart form data containing an audio file and model id.

### Remote OpenAI-compatible STT

The Unix orchestrator supports a remote transcription endpoint:

```bash
export STT_ENGINE=remote
export STT_REMOTE_URL=https://api.openai.com/v1/audio/transcriptions
export STT_REMOTE_MODEL=whisper-1
export STT_API_KEY=...
```

Credential precedence is:

1. `STT_REMOTE_KEY`
2. `STT_API_KEY`
3. `OPENAI_API_KEY`

No Authorization header is sent when the resolved key is empty, so an unauthenticated LAN endpoint can be used.

The Windows PowerShell orchestrator currently exposes the simpler `STT_URL` and `STT_MODEL` path. Do not assume every Unix remote-provider feature has PowerShell parity.

## Actual Unix fallback chains

Fallback behavior is determined by `service/tts.sh`. The selected engine runs first.

| Selected `TTS_ENGINE` | Attempt order |
|---|---|
| `supertonic` | Supertonic → NeuTTS → xAI |
| `qwen` | Qwen3-TTS → Supertonic → NeuTTS → xAI |
| `qwen-lazy` | Qwen lazy → Supertonic → NeuTTS → xAI |
| `neutts` | NeuTTS → Inflect Nano → Supertonic → xAI |
| `inflect` | Inflect Nano → NeuTTS → Supertonic → xAI |
| `openai` | OpenAI-compatible → Supertonic → NeuTTS |
| `inworld` | Inworld → Qwen3-TTS → Supertonic → NeuTTS, except auth failures stop immediately |
| `xai` | xAI → Supertonic → NeuTTS |

Important implications:

- A cloud provider is never contacted unless its engine is selected or it appears in that selected engine's chain and the preceding local attempts fail.
- `XAI_API_KEY` can remain unset; the xAI attempt then fails and the dispatcher reports that all engines failed if no earlier engine succeeded.
- `supertonic2` is not currently a valid dispatcher value.
- The PowerShell path does not necessarily implement the same complete provider/fallback matrix.

## Privacy and security

- Local VAD, Parakeet, and Supertonic keep microphone audio and reply text on the host.
- Remote STT sends recorded audio to the selected endpoint.
- Remote TTS sends reply text to the selected endpoint.
- Inworld steering may send text through both the steering model path and the synthesis provider path.
- Never commit credentials to `.env.example`, documentation, shell history, or issue reports.
- Prefer scoped credentials and LAN TLS/authentication when exposing speech servers beyond localhost.

## Quick recipes

Local low-latency conversation:

```bash
STT_ENGINE=local \
STT_URL=http://127.0.0.1:5093/v1/audio/transcriptions \
TTS_ENGINE=supertonic \
SUPERTONIC_URL=http://127.0.0.1:8766 \
TTS_QUALITY=normal \
talk.sh listen
```

One-way local announcement:

```bash
TALK_AUTO_LISTEN=0 \
TTS_ENGINE=supertonic \
SUPERTONIC_URL=http://127.0.0.1:8766 \
talk.sh speak "The task is complete."
```

Use an OpenAI-compatible server on the LAN:

```bash
TTS_ENGINE=openai \
OPENAI_TTS_URL=http://192.168.1.50:8000/v1 \
OPENAI_TTS_KEY=local-token \
talk.sh speak "Hello from the remote speech server."
```

Use the optional Supertonic 2 service:

```bash
TTS_ENGINE=supertonic \
SUPERTONIC_URL=http://127.0.0.1:8880 \
TTS_QUALITY=normal \
talk.sh speak "Fast local synthesis."
```
