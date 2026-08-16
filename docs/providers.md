# Speech providers and fallback policy

Local VoiceMode LLM is designed around a local speech path:

- Silero VAD on the host
- Parakeet STT on `127.0.0.1:5093`
- Supertonic TTS on `127.0.0.1:8766`

Remote providers and companion services are optional. Use them when a specific hosted voice is required, a slow machine needs offload, or provider-correct sentence direction adds value.

## Two TTS routing mechanisms

The Unix orchestrator supports two distinct routing layers.

### 1. Built-in dispatcher

When `TTS_SH` is unset, `talk.sh` runs `service/tts.sh`. `TTS_ENGINE` chooses the primary engine and its explicit fallback chain.

### 2. Implementation override

When `TTS_SH` points to another executable, `talk.sh` invokes that implementation instead. The AI Sentence Tagger / AI Voice Studio bridge uses this mechanism.

```bash
export TTS_SH="$HOME/.config/opencode/ai-tts-provider/tts-provider.sh"
```

An override bypasses the built-in dispatcher; `TTS_ENGINE` fallback does not run automatically.

## Recommended local baseline

```bash
export STT_ENGINE=local
export STT_URL=http://127.0.0.1:5093/v1/audio/transcriptions
export STT_MODEL=parakeet-tdt-0.6b-v3
export TTS_ENGINE=supertonic
export SUPERTONIC_URL=http://127.0.0.1:8766
export TTS_QUALITY=normal
```

The scripts inherit environment variables from their launcher. They do not automatically load `.env.example`.

## Deployment choices

| Situation | STT recommendation | TTS recommendation |
|---|---|---|
| Modern desktop or laptop | local Parakeet | local Supertonic |
| GPU reserved for the LLM | local Parakeet on CPU | local Supertonic on CPU |
| Apple Silicon with separate service | local Parakeet | Qwen3-TTS or Supertonic MLX |
| Old or heavily loaded CPU | local first | remote OpenAI-compatible TTS |
| Air-gapped or privacy-sensitive | local only | local only |
| Expressive hosted voice | local Parakeet | Inworld, xAI, or companion bridge |
| Verified xAI/Gemini catalogs and sentence direction | local Parakeet | AI Sentence Tagger / Voice Studio bridge |
| Speech service on a LAN host | configurable URL | OpenAI-compatible or bridge URL |

## Local TTS engines

### Supertonic 3

Default installed backend:

```bash
export TTS_ENGINE=supertonic
export SUPERTONIC_URL=http://127.0.0.1:8766
export SUPERTONIC_VOICE=F4
export TTS_QUALITY=normal
```

| Variable | Meaning |
|---|---|
| `SUPERTONIC_URL` | Managed installation endpoint; normally `:8766` |
| `SUPERTONIC_VOICE` | `F1`–`F5` or `M1`–`M5` |
| `TTS_QUALITY` | `normal` = 8 steps; `high` = 20 steps |
| `SUPERTONIC_STEPS` | Explicit 1–20 step override |
| `SUPERTONIC_SPEED` | Synthesis speed multiplier |
| `TTS_FADE_MS` | Edge fade used to reduce clicks |

### Supertonic 2

The optional service uses an OpenAI-compatible endpoint on `:8880`:

```bash
bash integrations/supertonic2/install.sh
TTS_ENGINE=supertonic \
SUPERTONIC_URL=http://127.0.0.1:8880 \
talk.sh speak "Hello from Supertonic 2"
```

There is no dedicated `supertonic2` dispatcher value; the URL chooses the compatible service.

### NeuTTS

```bash
export TTS_ENGINE=neutts
export NEUTTS_URL=http://127.0.0.1:8020
```

Language-specific model variables are available for English, Spanish, German, and French.

### Inflect Nano

```bash
export TTS_ENGINE=inflect
export INFLECT_URL=http://127.0.0.1:8030
```

Inflect is experimental and English-only. It declines other languages so the fallback chain can continue.

### Qwen3-TTS

```bash
export TTS_ENGINE=qwen
export QWEN_TTS_QUALITY=hq
export QWEN_TTS_VOICE=vivian
```

| Quality | Default URL |
|---|---|
| `fast` | `http://127.0.0.1:18881` |
| `hq` | `http://127.0.0.1:18882` |
| `lazy` | `http://127.0.0.1:18883` |

Set `QWEN_TTS_URL` to bypass quality-based URL selection.

### Windows IndexTTS

The Windows PowerShell orchestrator supports an IndexTTS CUDA service:

```powershell
$env:TTS_ENGINE = "indextts"
$env:INDEXTTS_URL = "http://127.0.0.1:7863"
$env:INDEXTTS_REF_AUDIO = "C:\voices\reference.wav"
.\windows\talk.ps1 speak "Hello"
```

A valid reference WAV is required. This path is implemented by `windows/talk.ps1`, not the Unix shell dispatcher.

## Shared AI Sentence Tagger / AI Voice Studio bridge

The optional bridge reuses a local companion service as the source of truth for xAI and Google Gemini voices, sentence direction, validation, and synthesis.

Supported contracts:

| Provider | Built-in voices | Default voice | Direction semantics | VoiceMode output |
|---|---:|---|---|---|
| xAI | 26 | `eve` | fixed 14 inline + 13 wrapping tags | WAV 48 kHz |
| Google Gemini | 30 | `Kore` | 16 common examples plus creative English direction | WAV 24 kHz |

Google's 16 examples are non-exhaustive. The companion enforces exact source preservation, literal bracket-cue handling, lexical boundaries, canonical voice casing, and PCM-to-WAV conversion.

### Install

```bash
bash integrations/ai-sentence-tagger/install.sh
```

### Select Google

```bash
export TTS_SH="$HOME/.config/opencode/ai-tts-provider/tts-provider.sh"
export AI_TTS_URL=http://127.0.0.1:8000
export AI_TTS_PROVIDER=google
export AI_TTS_VOICE=Kore
export AI_TTS_LANGUAGE=auto
```

### Select xAI

```bash
export TTS_SH="$HOME/.config/opencode/ai-tts-provider/tts-provider.sh"
export AI_TTS_URL=http://127.0.0.1:8000
export AI_TTS_PROVIDER=xai
export AI_TTS_VOICE=eve
```

The companion can be either:

- `groxaxo/xai-sentence-tagger`; or
- `groxaxo/xAI-Voice-Studio`.

Both expose the required stateless `/api/process/json` endpoint. The bridge does not create persistent Studio projects.

### Bridge variables

| Variable | Default | Purpose |
|---|---|---|
| `AI_TTS_URL` | `http://127.0.0.1:8000` | Companion base URL |
| `AI_TTS_PROVIDER` | `xai` | `xai`, `google`, or `gemini` |
| `AI_TTS_VOICE` | provider default | Case-insensitive built-in voice |
| `AI_TTS_SOURCE_LANGUAGE` | language passed by `talk.sh` | Tagging-language override |
| `AI_TTS_LANGUAGE` | source language | Synthesis language |
| `AI_TTS_COVERAGE` | `natural` | Direction coverage mode |
| `AI_TTS_STYLE_PROMPT` | unset | Gemini Director's Notes |
| `AI_TTS_MODEL` | companion default | Gemini TTS model override |
| `AI_TTS_TAGGER_MODEL` | companion default | Tagging-model override |
| `AI_TTS_TAGGER_BASE_URL` | companion default | Tagging endpoint override |
| `AI_TTS_TOKEN` | unset | Optional bearer token |
| `AI_TTS_TIMEOUT_SECONDS` | `180` | Request timeout |
| `AI_TTS_MAX_AUDIO_BYTES` | `100000000` | Decoded-audio limit |

The bridge forces WAV because pre-warmed listening and barge-in expect a single playable file. `AI_TTS_SAMPLE_RATE` is an advanced override and must be supported by the active provider.

### Catalog inspection

```bash
python3 ~/.config/opencode/ai-tts-provider/tts_provider.py providers
python3 ~/.config/opencode/ai-tts-provider/tts_provider.py voices --provider google
python3 ~/.config/opencode/ai-tts-provider/tts_provider.py tags --provider google
```

### Restore local-first routing

```bash
unset TTS_SH
export TTS_ENGINE=supertonic
```

See [the complete integration guide](../integrations/ai-sentence-tagger/README.md).

## Remote OpenAI-compatible TTS

The `openai` engine sends the standard speech payload to:

```text
<OPENAI_TTS_URL>/audio/speech
```

```bash
export TTS_ENGINE=openai
export OPENAI_TTS_URL=https://api.openai.com/v1
export OPENAI_TTS_KEY=replace-me
export OPENAI_TTS_MODEL=gpt-4o-mini-tts
export OPENAI_TTS_VOICE=alloy
export OPENAI_TTS_FORMAT=wav
```

`OPENAI_API_KEY` is used when `OPENAI_TTS_KEY` is unset. Compatibility is not guaranteed solely because a server advertises an OpenAI-like API; verify fields and returned audio.

## Inworld TTS

```bash
export TTS_ENGINE=inworld
export INWORLD_API_KEY=replace-with-basic-base64-key
export INWORLD_TTS_VOICE=Ashley
export INWORLD_TTS_MODEL=inworld-tts-2
export INWORLD_STEER=auto
```

Steering can improve expressiveness but adds a model call. Set `INWORLD_STEER=0` when time-to-first-audio is more important.

HTTP 401/403 is treated as a credential error and stops immediately rather than silently changing voice.

## Direct xAI TTS

The built-in Unix dispatcher can call xAI directly:

```bash
export TTS_ENGINE=xai
export XAI_API_KEY=replace-me
export XAI_TTS_VOICE=eve
```

This path sends text directly to xAI and does not run the shared AI Sentence Tagger provider validator. Use the companion bridge when exact shared tag/voice behavior is required.

## Speech-to-text providers

### Local Parakeet

```bash
export STT_ENGINE=local
export STT_URL=http://127.0.0.1:5093/v1/audio/transcriptions
export STT_MODEL=parakeet-tdt-0.6b-v3
```

### Remote OpenAI-compatible STT

```bash
export STT_ENGINE=remote
export STT_REMOTE_URL=https://api.openai.com/v1/audio/transcriptions
export STT_REMOTE_MODEL=whisper-1
export STT_API_KEY=replace-me
```

Credential precedence on Unix is:

1. `STT_REMOTE_KEY`
2. `STT_API_KEY`
3. `OPENAI_API_KEY`

No Authorization header is sent when the resolved key is empty, allowing unauthenticated private LAN endpoints.

## Built-in Unix fallback chains

These apply only when `TTS_SH` is unset.

| Selected `TTS_ENGINE` | Attempt order |
|---|---|
| `supertonic` | Supertonic → NeuTTS → xAI |
| `qwen` | Qwen3-TTS → Supertonic → NeuTTS → xAI |
| `qwen-lazy` | Qwen lazy → Supertonic → NeuTTS → xAI |
| `neutts` | NeuTTS → Inflect Nano → Supertonic → xAI |
| `inflect` | Inflect Nano → NeuTTS → Supertonic → xAI |
| `openai` | OpenAI-compatible → Supertonic → NeuTTS |
| `inworld` | Inworld → Qwen3-TTS → Supertonic → NeuTTS; auth failures stop |
| `xai` | xAI → Supertonic → NeuTTS |

Implications:

- Cloud providers are contacted only when selected or reached after preceding failures.
- An unset `XAI_API_KEY` causes the xAI attempt to fail without exposing a credential.
- `supertonic2` is not a dispatcher value.
- The AI bridge is not a dispatcher value; it is a `TTS_SH` override.
- Windows has a separate engine implementation and does not mirror every Unix path.

## Chunked playback

OpenAI-compatible, Inworld, and direct xAI paths can issue sentence requests concurrently while preserving playback order. `TTS_NO_PLAY=1` requires one file for pre-warmed listening or barge-in, so provider paths return or assemble one WAV.

The companion bridge sends one utterance to `/api/process/json`; provider-specific direction and synthesis are handled there, and one validated WAV is returned.

## Privacy and security

- Local VAD, Parakeet, and Supertonic keep microphone audio and reply text on the host.
- Remote STT sends recorded audio to the selected endpoint.
- Remote TTS sends reply text to the selected endpoint.
- The AI bridge sends reply text to the companion; the companion may send directed text to xAI or Google.
- Bind local services to loopback or a protected LAN.
- Never commit provider credentials or include them in prompts, logs, screenshots, or issue reports.
- Prefer scoped credentials and authenticated TLS when crossing host boundaries.

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

Google Gemini through the shared companion:

```bash
TTS_SH="$HOME/.config/opencode/ai-tts-provider/tts-provider.sh" \
AI_TTS_URL=http://127.0.0.1:8000 \
AI_TTS_PROVIDER=google \
AI_TTS_VOICE=Kore \
talk.sh speak "The release is ready."
```

OpenAI-compatible server on a LAN host:

```bash
TTS_ENGINE=openai \
OPENAI_TTS_URL=http://192.168.1.50:8000/v1 \
OPENAI_TTS_KEY=local-token \
talk.sh speak "Hello from the remote speech server."
```
