# Speech providers and fallback policy

Local VoiceMode LLM is designed around a local speech path:

- Silero VAD on the host
- Parakeet STT on `127.0.0.1:5093`
- Supertonic TTS on `127.0.0.1:8766`

Remote providers and companion services are optional. Use them when a specific hosted voice is required, a slow machine needs offload, or provider-correct sentence direction adds value.

## Unix TTS routing layers

### 1. Safety wrapper: `service/tts.sh`

When `TTS_SH` is unset, `talk.sh` invokes `service/tts.sh`. The wrapper interprets `TTS_ENGINE`, delegates ordinary engines to `service/tts_backends.sh`, and owns every direct or fallback xAI request.

The wrapper will not send an xAI request until every segmented sentence has at least one valid xAI speech tag. It also clears `XAI_API_KEY` while the historical dispatcher runs, so the old raw-xAI fallback cannot be reached.

### 2. Backend dispatcher: `service/tts_backends.sh`

This contains the existing Supertonic, Qwen, NeuTTS, Inflect Nano, OpenAI-compatible, Inworld, and legacy xAI implementation functions. The safety wrapper invokes it with xAI credentials intentionally hidden. A normal backend failure returns to the wrapper, which may perform a separately validated xAI fallback.

### 3. Implementation override: `TTS_SH`

When `TTS_SH` points to another executable, `talk.sh` invokes that implementation instead. The AI Sentence Tagger / AI Voice Studio bridge uses this mechanism:

```bash
export TTS_SH="$HOME/.config/opencode/ai-tts-provider/tts-provider.sh"
```

An override bypasses the built-in wrapper and dispatcher. The bridge therefore performs its own mandatory per-sentence proof before accepting audio.

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
| Expressive hosted voice | local Parakeet | Inworld or sentence-tagged xAI |
| Verified xAI/Gemini catalogs | local Parakeet | AI Sentence Tagger / Voice Studio bridge |
| Speech service on a LAN host | configurable URL | OpenAI-compatible or bridge URL |

## Local TTS engines

### Supertonic 3

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

```bash
bash integrations/supertonic2/install.sh
TTS_ENGINE=supertonic \
SUPERTONIC_URL=http://127.0.0.1:8880 \
talk.sh speak "Hello from Supertonic 2"
```

There is no dedicated `supertonic2` value; the compatible endpoint is selected by URL.

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

Inflect is experimental and English-only. It declines other languages so fallback can continue.

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

Set `QWEN_TTS_URL` to bypass quality-based selection.

### Windows IndexTTS

The Windows PowerShell orchestrator supports an IndexTTS CUDA service:

```powershell
$env:TTS_ENGINE = "indextts"
$env:INDEXTTS_URL = "http://127.0.0.1:7863"
$env:INDEXTTS_REF_AUDIO = "C:\voices\reference.wav"
.\windows\talk.ps1 speak "Hello"
```

A valid reference WAV is required. This path is implemented by `windows/talk.ps1`, not the Unix wrapper.

## Direct xAI TTS: mandatory sentence tagging

```bash
export TTS_ENGINE=xai
export XAI_API_KEY=replace-me
export XAI_TTS_VOICE=eve
export TTS_TAG_MODE=auto
```

All direct and fallback xAI requests pass through `service/xai_sentence_tagger.py` first. The helper:

1. segments the exact source into indexed sentences;
2. optionally asks an OpenAI-compatible model for context-aware xAI tags;
3. rejects missing, duplicate, unknown-tag, unbalanced, or source-rewriting rows;
4. deterministically repairs every invalid or omitted sentence;
5. reports `tagged_sentence_count == sentence_count`; and
6. fails before the provider request if any sentence remains untagged.

The fixed xAI grammar is 14 inline tags plus 13 wrapping tags.

### Tag modes

| `TTS_TAG_MODE` | Behavior |
|---|---|
| `auto` | Use a configured local model, then deterministically repair every invalid or missing sentence |
| `llm` | Prefer the configured model, with the same mandatory deterministic repair |
| `deterministic` | Make no tagging-model request; use validated local rules only |

### OpenAI-compatible local tagger

```bash
export TTS_TAGGER_URL=http://127.0.0.1:12434/v1
export TTS_TAGGER_MODEL=your-local-model
export TTS_TAGGER_API_KEY=not-needed
export TTS_TAGGER_TEMPERATURE=0.2
export TTS_TAGGER_TIMEOUT_SECONDS=30
```

Inspect the result without synthesizing:

```bash
printf '%s' 'Hello. Are you there?' | \
  python3 service/xai_sentence_tagger.py \
    --mode deterministic --language en --format json | python3 -m json.tool
```

See [Mandatory xAI sentence tagging](xai-sentence-tagging.md).

## Shared AI Sentence Tagger / AI Voice Studio bridge

The optional bridge reuses a local companion service as the source of truth for xAI and Google Gemini voices, sentence direction, validation, and synthesis.

| Provider | Built-in voices | Default voice | Direction semantics | VoiceMode output |
|---|---:|---|---|---|
| xAI | 26 | `eve` | fixed 14 inline + 13 wrapping tags | WAV 48 kHz |
| Google Gemini | 30 | `Kore` | 16 common examples plus creative English direction | WAV 24 kHz |

The bridge requests `include_annotations=true` and refuses audio unless the companion proves:

- one annotation per source sentence;
- `tagged_sentence_count == sentence_count`;
- no untagged indexes; and
- inserted provider direction in every annotation.

### Install

```bash
bash integrations/ai-sentence-tagger/install.sh
```

### Google

```bash
export TTS_SH="$HOME/.config/opencode/ai-tts-provider/tts-provider.sh"
export AI_TTS_URL=http://127.0.0.1:8000
export AI_TTS_PROVIDER=google
export AI_TTS_VOICE=Kore
export AI_TTS_LANGUAGE=auto
```

### xAI

```bash
export TTS_SH="$HOME/.config/opencode/ai-tts-provider/tts-provider.sh"
export AI_TTS_URL=http://127.0.0.1:8000
export AI_TTS_PROVIDER=xai
export AI_TTS_VOICE=eve
```

The companion can be either `groxaxo/xai-sentence-tagger` or `groxaxo/xAI-Voice-Studio`. Both expose `/api/process/json`; the bridge remains stateless and does not create persistent Studio projects.

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
| `AI_TTS_MODEL` | companion default | TTS model override |
| `AI_TTS_TAGGER_MODEL` | companion default | Tagging-model override |
| `AI_TTS_TAGGER_BASE_URL` | companion default | Tagging endpoint override |
| `AI_TTS_TOKEN` | unset | Optional bearer token |
| `AI_TTS_TIMEOUT_SECONDS` | `180` | Request timeout |
| `AI_TTS_MAX_AUDIO_BYTES` | `100000000` | Decoded-audio limit |

The bridge forces WAV because pre-warmed listening and barge-in expect one playable file.

### Catalog inspection

```bash
python3 ~/.config/opencode/ai-tts-provider/tts_provider.py providers
python3 ~/.config/opencode/ai-tts-provider/tts_provider.py voices --provider google
python3 ~/.config/opencode/ai-tts-provider/tts_provider.py tags --provider google
```

Restore the built-in local-first path with:

```bash
unset TTS_SH
export TTS_ENGINE=supertonic
```

See [the complete bridge guide](../integrations/ai-sentence-tagger/README.md).

## Remote OpenAI-compatible TTS

```bash
export TTS_ENGINE=openai
export OPENAI_TTS_URL=https://api.openai.com/v1
export OPENAI_TTS_KEY=replace-me
export OPENAI_TTS_MODEL=gpt-4o-mini-tts
export OPENAI_TTS_VOICE=alloy
export OPENAI_TTS_FORMAT=wav
```

The engine sends the standard speech payload to `<OPENAI_TTS_URL>/audio/speech`. `OPENAI_API_KEY` is used when `OPENAI_TTS_KEY` is unset.

## Inworld TTS

```bash
export TTS_ENGINE=inworld
export INWORLD_API_KEY=replace-with-basic-base64-key
export INWORLD_TTS_VOICE=Ashley
export INWORLD_TTS_MODEL=inworld-tts-2
export INWORLD_STEER=auto
```

HTTP 401/403 remains terminal. The safety wrapper preserves exit status 3 and does not hide credential refusal behind an xAI fallback.

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

Credential precedence on Unix is `STT_REMOTE_KEY`, then `STT_API_KEY`, then `OPENAI_API_KEY`. No Authorization header is sent when the resolved key is empty.

## Effective Unix fallback chains

These apply only when `TTS_SH` is unset. `tagged xAI` always means the hard per-sentence audit passed first.

| Selected `TTS_ENGINE` | Effective attempt order |
|---|---|
| `supertonic` | Supertonic → NeuTTS → tagged xAI |
| `qwen` | Qwen3-TTS → Supertonic → NeuTTS → tagged xAI |
| `qwen-lazy` | Qwen lazy → Supertonic → NeuTTS → tagged xAI |
| `neutts` | NeuTTS → Inflect Nano → Supertonic → tagged xAI |
| `inflect` | Inflect Nano → NeuTTS → Supertonic → tagged xAI |
| `openai` | OpenAI-compatible → Supertonic → NeuTTS → tagged xAI |
| `inworld` | Inworld → Qwen3-TTS → Supertonic → NeuTTS → tagged xAI on non-auth failure |
| `xai` | tagged xAI → Supertonic → NeuTTS |

Unknown engines retain exit status 2. Explicit credential refusals retain exit status 3. Neither falls back to xAI.

## Chunking and playback

OpenAI-compatible and Inworld implementations can issue sentence requests concurrently while preserving playback order. Direct xAI intentionally sends the fully directed document only after the complete sentence invariant has been checked.

`TTS_NO_PLAY=1` requires one file for pre-warmed listening or barge-in, so every successful path returns or assembles one WAV.

## Privacy and security

- Local VAD, Parakeet, Supertonic, and deterministic tag repair keep data on the host.
- A configured local tagging endpoint receives reply text.
- Remote STT sends recorded audio to the selected endpoint.
- Remote TTS sends directed reply text to the selected provider.
- The companion bridge sends reply text to the companion, which may contact xAI or Google.
- Bind local services to loopback or a protected LAN.
- Never commit provider credentials or include them in prompts, logs, screenshots, or issue reports.
