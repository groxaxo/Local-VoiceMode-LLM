# TTS & STT Providers — Local CPU vs. Remote

Local VoiceMode runs **entirely on your CPU by default** — no API keys, no cloud.
That is the whole point of the project. But not every CPU is fast enough for a
snappy back-and-forth: on an old laptop, a low-power mini-PC, or a heavily loaded
box, even the 8-step Supertonic engine can fall behind a live conversation.

For those cases you can **offload TTS and/or STT to a remote OpenAI-compatible
endpoint** while keeping the exact same `talk` workflow. Nothing else changes —
the VAD, the loop, the skill, the commands are identical. You only swap which
engine synthesizes the audio (and, optionally, which one transcribes).

This page is the map: pick local or remote per stage, depending on your hardware.

---

## When to stay local vs. go remote

| Your situation | TTS | STT |
|----------------|-----|-----|
| Modern desktop / Apple Silicon / decent laptop | **local** (`supertonic`) | **local** (Parakeet) |
| Slow or old CPU, TTS lags the conversation | **remote** (`openai`) | local (Parakeet is light) |
| Very slow CPU, even STT struggles | remote (`openai`) | **remote** (`whisper-1`) |
| Want the most expressive voice, don't mind cloud | **remote** (`inworld`) | local |
| Air-gapped / privacy-critical / offline | local only | local only |

> Rule of thumb: **STT (Parakeet) is cheap** (~300 ms, 8–21× realtime even on a
> mid CPU), so it rarely needs offloading. **TTS is the heavier stage** — if
> anything feels slow, move TTS to a remote engine first and leave STT local.

---

## TTS engines

Select with `TTS_ENGINE`. Every engine falls back to the local ones if it fails
(see [Fallback policy](#fallback-policy)).

| Engine | Where it runs | Needs | Notes |
|--------|---------------|-------|-------|
| `supertonic` *(default)* | Local CPU (ONNX, `:8766`) | nothing | Auto-installed. EN/ES/KO/PT/FR. |
| `supertonic2` | Local CPU (ONNX, `:8880`) | opt-in install | ~3× faster than Supertonic 3. |
| `neutts` | Local CPU (GGUF, `:8020`) | separate backend | EN/ES/DE/FR. |
| `openai` | **Remote** OpenAI-compatible | `OPENAI_API_KEY` | Slow-CPU offload. Streams by sentence. |
| `inworld` | **Remote** Inworld cloud | `INWORLD_API_KEY` | Expressive (per-sentence steering). |
| `xai` | **Remote** xAI cloud | `XAI_API_KEY` | Last-resort fallback. |

### `openai` — generic OpenAI-compatible remote (the slow-CPU offload)

Hits `<OPENAI_TTS_URL>/audio/speech` with the standard OpenAI speech schema, so it
works with:

- **OpenAI** itself (`https://api.openai.com/v1`)
- a **hosted provider** that exposes an OpenAI-compatible speech endpoint
- **your own remote box** running an OpenAI-compatible server (e.g. a GPU machine
  on your LAN running vLLM / an OpenAI-shim TTS server)

```bash
export TTS_ENGINE=openai
export OPENAI_API_KEY=sk-...            # or OPENAI_TTS_KEY
export OPENAI_TTS_MODEL=gpt-4o-mini-tts # or tts-1, tts-1-hd
export OPENAI_TTS_VOICE=alloy           # alloy, echo, fable, onyx, nova, shimmer
# point at your own server instead of OpenAI:
# export OPENAI_TTS_URL=http://192.168.1.50:8000/v1
```

Like the xAI path, it **chunks the reply on sentence boundaries and streams** —
requests fire in parallel and playback starts on the first sentence, so you hear
the answer begin while the rest is still synthesizing.

| Variable | Default | Purpose |
|----------|---------|---------|
| `OPENAI_TTS_URL` | `https://api.openai.com/v1` | OpenAI-compatible base URL (no trailing `/audio/speech`) |
| `OPENAI_TTS_KEY` | `$OPENAI_API_KEY` | Bearer key |
| `OPENAI_TTS_MODEL` | `gpt-4o-mini-tts` | Speech model id |
| `OPENAI_TTS_VOICE` | `alloy` | Voice id |
| `OPENAI_TTS_FORMAT` | `wav` | Response format (keep `wav` for zero-transcode playback) |

### `inworld` — expressive remote cloud

Inworld's TTS-2 supports **steering**: a small LLM pre-processor
(`service/inworld_steer.sh`) rewrites each sentence with natural-language delivery
tags (`[warm and teasing with a playful lilt] ...`) so the voice is emotionally
present instead of flat. The steering runs **per sentence, inside the parallel
synth jobs**, so the LLM rewrite of one sentence overlaps the synthesis of the
others rather than blocking the whole reply up front.

```bash
export TTS_ENGINE=inworld
export INWORLD_API_KEY=...        # base64 "Basic" key from platform.inworld.ai/api-keys
export INWORLD_TTS_VOICE=Ashley   # 260 voices via the list-voices API
export INWORLD_TTS_MODEL=inworld-tts-2
# export INWORLD_STEER=0          # disable steering → ~2s faster first audio, flatter voice
```

| Variable | Default | Purpose |
|----------|---------|---------|
| `INWORLD_API_KEY` | *(required)* | Basic/base64 key (also read from `INWORLD_TTS_API`) |
| `INWORLD_TTS_VOICE` | `Ashley` | Voice id |
| `INWORLD_TTS_MODEL` | `inworld-tts-2` | `inworld-tts-2` / `inworld-tts-2-max` |
| `INWORLD_STEER` | `auto` | `auto` (on for tts-2) / `1` / `0` (disable) |
| `INWORLD_STEER_PERSONA` | *(empty)* | Optional persona to bias delivery tags |
| `INWORLD_STEER_MODEL` | `openai/gpt-4o-mini` | LLM-router model used by the steerer |

> **Latency note:** steering adds a per-sentence LLM round-trip (~1–2 s) in front
> of the *first* audio. It is parallelized so it does not compound on long replies,
> but if you want the snappiest possible start, set `INWORLD_STEER=0` (you lose the
> expressive delivery tags, not the voice). A bad/forbidden Inworld key fails loudly
> (HTTP 401/403) and does **not** silently fall back to a different voice.

---

## STT engines

STT is selected with `STT_ENGINE` (`local` or `remote`). Local Parakeet needs no
key. For a remote OpenAI-compatible transcription endpoint (e.g. OpenAI Whisper),
set the remote URL/model and a bearer key:

```bash
export STT_ENGINE=remote
export STT_REMOTE_URL=https://api.openai.com/v1/audio/transcriptions
export STT_REMOTE_MODEL=whisper-1
export STT_API_KEY=sk-...    # or STT_REMOTE_KEY / OPENAI_API_KEY
```

The bearer header is only sent when a key is set, so pointing `STT_REMOTE_URL` at
another *local* OpenAI-compatible server (no auth) still works.

| Variable | Default | Purpose |
|----------|---------|---------|
| `STT_ENGINE` | `local` | `local` (Parakeet `:5093`) or `remote` |
| `STT_REMOTE_URL` | local `:5093` | Remote `/v1/audio/transcriptions` endpoint |
| `STT_REMOTE_MODEL` | `$STT_MODEL` | e.g. `whisper-1` |
| `STT_API_KEY` | `$STT_REMOTE_KEY`/`$OPENAI_API_KEY` | Bearer key (empty = no auth header) |

---

## Fallback policy

When the **primary** engine is local, the local engines are always exhausted
before any cloud — the cloud is only used if every local engine fails. When you
**explicitly** pick a remote engine, that choice is honored first, then it still
falls back to the local engines so a dropped network connection never leaves you
mute.

| Primary | Order |
|---------|-------|
| `supertonic` *(default)* | supertonic → neutts → xai |
| `supertonic2` | supertonic2 → supertonic → neutts → xai |
| `neutts` | neutts → supertonic → xai |
| `openai` | openai → supertonic → neutts |
| `inworld` | inworld → supertonic → neutts → xai |
| `xai` | xai → supertonic → neutts |

> Exception: an Inworld **auth** failure (401/403) is treated as a config error
> you must fix, so it exits loudly instead of silently switching voices.

---

## Quick recipes

```bash
# Slowest part is TTS on an old CPU → offload just TTS to OpenAI:
TTS_ENGINE=openai OPENAI_API_KEY=sk-... talk.sh speak "Hello"

# Run your own remote OpenAI-compatible TTS box on the LAN:
TTS_ENGINE=openai OPENAI_TTS_URL=http://192.168.1.50:8000/v1 OPENAI_TTS_KEY=x talk.sh speak "Hi"

# Most expressive voice, latency be damned:
TTS_ENGINE=inworld INWORLD_API_KEY=... INWORLD_TTS_VOICE=Olivia talk.sh speak "Hello"

# Everything remote (very slow CPU):
STT_ENGINE=remote STT_REMOTE_URL=https://api.openai.com/v1/audio/transcriptions \
  STT_REMOTE_MODEL=whisper-1 STT_API_KEY=sk-... \
  TTS_ENGINE=openai OPENAI_API_KEY=sk-... talk.sh loop
```
