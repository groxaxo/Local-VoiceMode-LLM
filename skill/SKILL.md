---
name: talk
description: >-
  Runs a real VAD-driven voice conversation through Local VoiceMode LLM: Silero
  microphone endpointing, Parakeet speech-to-text, and configured local or remote
  text-to-speech. Use when the user asks to talk, use voice mode, speak, listen,
  read a response aloud, or continue a spoken conversation. Triggers include:
  voice, talk, speak, listen, habla, voz, audio, tts, stt.
---

# Talk — real voice conversation

Use the installed Local VoiceMode LLM scripts. Never invent a transcript, claim audio was played without invoking the tool, or simulate microphone input.

## Runtime paths

| Role | Unix/macOS | Windows |
|---|---|---|
| Orchestrator | `~/.config/opencode/skills/talk/talk.sh` | `%USERPROFILE%\.config\opencode\skills\talk\talk.ps1` |
| Recorder | `~/.config/opencode/skills/talk/vad_recorder.py` | skill-local `vad_recorder.py` |
| Built-in TTS dispatcher | `~/.config/opencode/tts.sh` | provider logic in `talk.ps1` |
| Language helper | `~/.config/opencode/tts_lang.sh` | orchestrator language argument |
| Shared AI provider bridge | `~/.config/opencode/ai-tts-provider/tts-provider.sh` | Python helper is portable; automatic PowerShell routing is separate |

Supported skill targets:

| Agent | Skill path |
|---|---|
| Claude Code | `~/.claude/skills/talk/` |
| OpenCode CLI | `~/.config/opencode/skills/talk/` |
| OpenClaw | `~/.openclaw/skills/talk/` |
| Hermes Agent | `~/.hermes/skills/talk/` |
| Codex | `~/.codex/skills/talk/` |

Default managed local endpoints:

| Service | Endpoint |
|---|---|
| Parakeet STT | `http://127.0.0.1:5093/v1/audio/transcriptions` |
| Supertonic 3 TTS | `http://127.0.0.1:8766` |

The launching shell should set `SUPERTONIC_URL=http://127.0.0.1:8766` explicitly so the dispatcher and installed service agree.

## Commands

Unix/macOS:

```bash
~/.config/opencode/skills/talk/talk.sh listen
~/.config/opencode/skills/talk/talk.sh speak "Hello"
~/.config/opencode/skills/talk/talk.sh status
~/.config/opencode/skills/talk/talk.sh devices
~/.config/opencode/skills/talk/talk.sh pick
```

Windows PowerShell:

```powershell
& "$env:USERPROFILE\.config\opencode\skills\talk\talk.ps1" listen
& "$env:USERPROFILE\.config\opencode\skills\talk\talk.ps1" speak "Hello"
& "$env:USERPROFILE\.config\opencode\skills\talk\talk.ps1" status
& "$env:USERPROFILE\.config\opencode\skills\talk\talk.ps1" devices
```

## Conversation protocol

### Initial turn

Call `listen` exactly once when entering voice mode.

```text
transcript = talk.sh listen
```

- Stdout is the user's transcribed utterance.
- Diagnostics are written to stderr.
- Empty stdout means no completed turn or a clean session end.
- Never fabricate input when stdout is empty.

### Subsequent turns

After reasoning about the transcript, produce a concise spoken reply and call `speak`:

```text
next_transcript = talk.sh speak "assistant reply"
```

With `TALK_AUTO_LISTEN=1`, `speak`:

1. synthesizes the assistant reply;
2. plays it;
3. plays the ready cue;
4. activates the microphone;
5. records the next user turn;
6. transcribes it;
7. prints the next transcript to stdout.

Do **not** call `listen` after `speak`; doing so opens a second recording cycle.

### Loop

```text
listen once
while transcript is non-empty:
    produce a brief spoken response
    transcript = speak(response)
stop when stdout is empty
```

Empty stdout from `speak` is the session-end signal. Exit cleanly instead of trying to recover with another listen call.

## Spoken-response style

- Lead with the answer or result.
- Prefer short paragraphs and natural sentences.
- Do not read long URLs, raw stack traces, large tables, or code blocks aloud.
- Summarize technical detail and keep exact commands in the text response.
- Ask only one spoken question at a time.
- Never narrate hidden reasoning or internal chain-of-thought.

## One-way read-aloud

```bash
TALK_AUTO_LISTEN=0 \
SUPERTONIC_URL=http://127.0.0.1:8766 \
talk.sh speak "The task completed successfully."
```

## Session termination

| Signal | Behavior |
|---|---|
| Keyboard interruption | running process stops |
| Idle timeout | stdout is empty after `TALK_IDLE_TIMEOUT_S` |
| Spoken stop phrase | matching `TALK_STOP_PHRASES` returns empty stdout |

Use specific stop phrases because matching is case-insensitive substring matching:

```bash
export TALK_STOP_PHRASES="end voice mode|stop the conversation|para de hablar"
```

## Recommended local environment

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

The scripts do not automatically source `.env.example`.

## TTS routing

### Built-in Unix dispatcher

When `TTS_SH` is unset, `TTS_ENGINE` selects the primary implementation in `service/tts.sh`:

```text
supertonic, qwen, qwen-lazy, neutts, inflect, openai, inworld, xai
```

Supertonic 2 has no separate alias; point the compatible Supertonic client at `:8880`.

### Shared xAI / Google Gemini bridge

For provider-correct sentence direction and the shared 26/30-voice catalogs, install:

```bash
bash integrations/ai-sentence-tagger/install.sh
```

Then select Google:

```bash
export TTS_SH="$HOME/.config/opencode/ai-tts-provider/tts-provider.sh"
export AI_TTS_URL=http://127.0.0.1:8000
export AI_TTS_PROVIDER=google
export AI_TTS_VOICE=Kore
export AI_TTS_LANGUAGE=auto
```

Or xAI:

```bash
export TTS_SH="$HOME/.config/opencode/ai-tts-provider/tts-provider.sh"
export AI_TTS_URL=http://127.0.0.1:8000
export AI_TTS_PROVIDER=xai
export AI_TTS_VOICE=eve
```

The bridge calls a local AI Sentence Tagger or AI Voice Studio companion. The companion owns the local tagging model and provider credentials.

Important rules:

- `TTS_SH` is an implementation override, not a `TTS_ENGINE` value.
- Setting it bypasses the built-in fallback graph.
- Unset `TTS_SH` to restore local-first `TTS_ENGINE` routing.
- The bridge uses stateless `/api/process/json`; it does not create persistent Studio projects.
- Google has 30 canonical voices and creative English directions; its 16 common examples are non-exhaustive.
- xAI has 26 canonical built-in voices and a fixed 27-tag grammar.
- The adapter forces WAV and preserves the `TTS_NO_PLAY=1` single-file contract used by pre-warmed listening and barge-in.

## Important environment variables

| Variable | Purpose |
|---|---|
| `STT_ENGINE` | Unix STT routing: `local` or `remote` |
| `STT_URL` / `STT_MODEL` | local transcription endpoint and model |
| `STT_REMOTE_URL` / `STT_API_KEY` | remote transcription |
| `TTS_ENGINE` | built-in primary TTS engine |
| `TTS_SH` | Unix TTS implementation override |
| `SUPERTONIC_URL` / `SUPERTONIC_VOICE` | local Supertonic service and voice |
| `TTS_QUALITY` | `normal` for 8 steps or `high` for 20 |
| `AI_TTS_URL` | AI Sentence Tagger / Voice Studio companion URL |
| `AI_TTS_PROVIDER` | `xai`, `google`, or `gemini` |
| `AI_TTS_VOICE` | provider voice ID |
| `AI_TTS_STYLE_PROMPT` | Gemini Director's Notes |
| `VAD_THRESHOLD` | speech sensitivity |
| `VAD_MIN_SILENCE_MS` | silence needed to close a turn |
| `MIC_QUERY` | input-device name substring |
| `TALK_AUTO_LISTEN` | listen after playback |
| `TALK_BARGE_IN` | interrupt playback on detected speech |
| `TALK_IDLE_TIMEOUT_S` | end an idle session; `0` disables |
| `TALK_STOP_PHRASES` | pipe-separated spoken stop phrases |

Do not assume that every Unix provider feature exists in the Windows PowerShell orchestrator. Windows supports its own Supertonic, direct xAI, and IndexTTS paths; the companion Python helper is portable, but this installer does not automatically rewrite PowerShell routing.

## Barge-in

`TALK_BARGE_IN=1` starts VAD during playback and stops audio when speech is detected. It is not acoustic echo cancellation. Speaker bleed can interrupt the assistant's own voice; prefer headphones or leave it disabled.

## Troubleshooting rules

1. Run `status` after installation or service restart.
2. Run `devices` and select the microphone explicitly when capture is uncertain.
3. Force the managed TTS endpoint with `SUPERTONIC_URL=http://127.0.0.1:8766`.
4. Inspect `TTS_SH` before diagnosing `TTS_ENGINE`; an override bypasses the dispatcher.
5. For the AI bridge, run its `health`, `providers`, and `voices` catalog commands before synthesis.
6. For missed speech, lower `VAD_THRESHOLD`; for background triggers, raise it.
7. For premature turn endings, raise `VAD_MIN_SILENCE_MS`.
8. If all TTS paths fail, report the actual backend error; never substitute system TTS and claim the configured voice played.
9. Never expose API keys in logs, messages, screenshots, or committed commands.
10. Respect empty stdout as a deliberate session-end signal.

Full operator guidance is in `docs/troubleshooting.md`, `docs/providers.md`, and `docs/ai-provider-bridge.md`.
