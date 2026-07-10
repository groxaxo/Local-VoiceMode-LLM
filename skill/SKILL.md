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

Supported skill targets:

| Agent | Skill path |
|---|---|
| Claude Code | `~/.claude/skills/talk/` |
| OpenCode CLI | `~/.config/opencode/skills/talk/` |
| OpenClaw | `~/.openclaw/skills/talk/` |
| Hermes Agent | `~/.hermes/skills/talk/` |
| Codex | `~/.codex/skills/talk/` |

## Runtime paths

Use the script inside the active skill directory when possible. The canonical OpenCode installation is:

| Role | Path |
|---|---|
| Unix orchestrator | `~/.config/opencode/skills/talk/talk.sh` |
| Windows orchestrator | `%USERPROFILE%\.config\opencode\skills\talk\talk.ps1` |
| Recorder | `~/.config/opencode/skills/talk/vad_recorder.py` |
| TTS dispatcher | `~/.config/opencode/tts.sh` |
| Language helper | `~/.config/opencode/tts_lang.sh` |

Default managed local services:

| Service | Endpoint |
|---|---|
| Parakeet STT | `http://127.0.0.1:5093/v1/audio/transcriptions` |
| Supertonic 3 TTS | `http://127.0.0.1:8766` |

The launching process should set `SUPERTONIC_URL=http://127.0.0.1:8766` explicitly so the dispatcher and installed service agree.

## Commands

Unix:

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
- Empty stdout means no completed turn or a clean session end. Do not fabricate input.

### Subsequent turns

After reasoning about the transcript, give a concise spoken reply and call `speak`:

```text
next_transcript = talk.sh speak "assistant reply"
```

With `TALK_AUTO_LISTEN=1`, `speak` performs all of the following:

1. Synthesize the assistant reply.
2. Play it.
3. Play the ready cue/beep.
4. Open or activate the microphone.
5. Record the next user turn.
6. Transcribe it.
7. Print the next transcript to stdout.

Do **not** call `listen` after `speak`; doing so opens a second recording cycle and breaks the conversation protocol.

### Loop

```text
listen once
while transcript is non-empty:
    produce a brief spoken response
    transcript = speak(response)
stop when stdout is empty
```

Empty stdout from `speak` is the session-end signal. Exit cleanly and do not try to recover by listening again.

## Spoken-response style

Voice responses should be easy to understand when heard once:

- Lead with the answer or result.
- Prefer short paragraphs and natural sentences.
- Avoid reading long URLs, raw stack traces, tables, or large code blocks aloud.
- Summarize technical detail and leave exact commands in the text response when appropriate.
- Ask only one spoken question at a time.
- Do not narrate hidden reasoning or internal chain-of-thought.

## One-way read-aloud

For a spoken notification without reopening the microphone:

```bash
TALK_AUTO_LISTEN=0 \
SUPERTONIC_URL=http://127.0.0.1:8766 \
talk.sh speak "The task completed successfully."
```

## Session termination

A session can end through:

| Signal | Behavior |
|---|---|
| Keyboard interruption | The running process is stopped |
| Idle timeout | `listen` completes with empty stdout after `TALK_IDLE_TIMEOUT_S` |
| Spoken stop phrase | A configured phrase in `TALK_STOP_PHRASES` produces empty stdout |

`TALK_STOP_PHRASES` is pipe-separated and uses case-insensitive substring matching. A safer explicit configuration is:

```bash
export TALK_STOP_PHRASES="end voice mode|stop the conversation|para de hablar"
```

Because matching is permissive, avoid very short stop phrases that are likely to appear in normal speech.

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

The scripts do not automatically source the repository `.env.example`.

## Important environment variables

| Variable | Purpose |
|---|---|
| `STT_ENGINE` | Unix STT routing: `local` or `remote` |
| `STT_URL` | Local transcription endpoint |
| `STT_MODEL` | Local model id |
| `STT_REMOTE_URL` | Unix remote transcription endpoint |
| `STT_REMOTE_MODEL` | Unix remote model id |
| `STT_API_KEY` | Optional remote STT bearer token |
| `TTS_ENGINE` | Unix primary TTS dispatcher value |
| `SUPERTONIC_URL` | Supertonic-compatible endpoint; managed default is `:8766` |
| `SUPERTONIC_VOICE` | Supertonic voice id, `F1`–`F5` or `M1`–`M5` |
| `TTS_QUALITY` | `normal` for 8 steps or `high` for 20 steps |
| `TTS_FADE_MS` | Edge fade in milliseconds |
| `VAD_THRESHOLD` | Speech sensitivity |
| `VAD_MIN_SILENCE_MS` | Silence required to close a turn |
| `MIC_QUERY` | Input-device name substring |
| `TALK_AUTO_LISTEN` | Listen after playback |
| `TALK_BARGE_IN` | Interrupt playback on detected speech |
| `TALK_IDLE_TIMEOUT_S` | End an idle session after N seconds; `0` disables |
| `TALK_STOP_PHRASES` | Pipe-separated spoken stop phrases |

Unix `TTS_ENGINE` values implemented by the current dispatcher:

```text
supertonic, qwen, qwen-lazy, neutts, inflect, openai, inworld, xai
```

The optional Supertonic 2 service has no dedicated alias today. Select it through the compatible client:

```bash
TTS_ENGINE=supertonic SUPERTONIC_URL=http://127.0.0.1:8880 talk.sh speak "Hello"
```

Do not assume that every Unix provider feature is implemented by the Windows PowerShell orchestrator.

## Barge-in

`TALK_BARGE_IN=1` starts VAD during playback and stops audio when speech is detected. Enable it only when the microphone does not strongly capture the speakers.

It is not acoustic echo cancellation. With speaker bleed, the assistant's own voice can trigger an interruption. Prefer headphones or leave barge-in disabled.

## Troubleshooting rules

1. Run `status` after installation or service restart.
2. Run `devices` and select the microphone explicitly when capture is uncertain.
3. Force the managed TTS endpoint with `SUPERTONIC_URL=http://127.0.0.1:8766`.
4. For missed speech, lower `VAD_THRESHOLD`; for background triggers, raise it.
5. For premature turn endings, raise `VAD_MIN_SILENCE_MS`.
6. If all TTS engines fail, report the backend error; do not substitute system TTS and claim the configured voice played.
7. Never expose API keys in logs, messages, or commands that will be committed.
8. Respect empty stdout as a deliberate session-end signal.

Full operator guidance is in `docs/troubleshooting.md` in the Local VoiceMode LLM repository.
