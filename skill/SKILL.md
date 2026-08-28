---
name: talk
description: >-
  Orchestrates VAD-driven voice conversation (Silero VAD listen, xAI cloud STT,
  xAI cloud TTS voice eve by default; local TTS engines removed from the default path).
  Use when the user says talk, voice, speak, habla, voz, audio, talk mode, or wants
  spoken back-and-forth. Also when they ask to read a reply aloud (say it, speak that).
  Triggers on: voice, talk, speak, habla, audio, tts, stt.
---

# Talk — Local voice conversation

Works with **Claude Code**, **OpenCode CLI**, **OpenClaw**, **Hermes Agent**, and **Codex**.

Load via `skill("talk")` in any supported agent. The same `SKILL.md` is installed to
each agent's skills directory by `setup.sh` / `setup.ps1`.

| Agent | Skill path |
|-------|-----------|
| Claude Code  | `~/.claude/skills/talk/` |
| OpenCode CLI | `~/.config/opencode/skills/talk/` |
| OpenClaw     | `~/.openclaw/skills/talk/` |
| Hermes Agent | `~/.hermes/skills/talk/` |
| Codex        | `~/.codex/skills/talk/` |

**Default STT:** **xAI cloud** — `POST https://api.x.ai/v1/stt` (non-streaming), needs `XAI_API_KEY`. Same key as the TTS side. Switched from local Parakeet on 2026-08-19: the `com.opencode.parakeet-stt` launchd job was booted out and `launchctl disable`d to reclaim ~1.8 GB of resident footprint on a 24 GB Mac that was swapping hard.

> **xAI STT is NOT OpenAI-compatible.** There is no `model` field, and `file` **must be the last multipart field**. Response is `{text, language, duration, words[]}`. The streaming WebSocket endpoint (`wss://api.x.ai/v1/stt`) is deliberately unused — turn endpointing is already done locally by `vad_recorder.py`, so only complete utterances are ever uploaded.

| Env var | Default | Effect |
|---|---|---|
| `STT_ENGINE` | `xai` | `xai` \| `local` \| `remote` |
| `XAI_STT_URL` | `https://api.x.ai/v1/stt` | endpoint |
| `XAI_STT_LANGUAGE` | *(empty)* | empty = auto-detect, required for es/en code-switching. Setting it also sends `format=true`, enabling Inverse Text Normalization ("twenty seven" → "27") |
| `XAI_STT_FILLER_WORDS` | `false` | keep "um"/"uh" in the transcript |
| `XAI_STT_VAD_THRESHOLD` | *(unset)* | xAI-side speech gate 0.0–1.0 (their default 0.5); `0` disables |

**Falling back to local Parakeet** (re-enables the ~1.8 GB service):
```bash
launchctl enable gui/501/com.opencode.parakeet-stt
launchctl bootstrap gui/501 ~/Library/LaunchAgents/com.opencode.parakeet-stt.plist
STT_ENGINE=local ~/.config/opencode/skills/talk/talk.sh status
```

**Default TTS:** **xAI cloud** (`https://api.x.ai/v1/tts`, needs `XAI_API_KEY`) with voice **`eve`**. Long replies are chunked at sentence boundaries and synthesized in parallel. Local TTS engines (qwen3-mlx, chatterbox, supertonic, qwen, neutts, inflect, vibevoice) were **removed from the default speak path** — they do not work on this setup — but remain selectable per call with `TTS_ENGINE=<name>`. `say`/TTS-system fallback is intentionally disabled.

Codex and Claude Code symlink this same skill directory, so this xAI default is
shared by Codex, Claude, and OpenCode.

**Audio playback:** `afplay` (macOS), `ffplay`/`aplay`/`paplay` (Linux), `ffplay`/SoundPlayer (Windows via `talk.ps1`).

> **Port note:** Supertonic defaults to `:8766` (not `:8765`) so it can coexist
> with the existing Chatterbox TTS server on `:8765`. If a precompiled
> `speech-server` already runs on `:5093` for STT, setup.sh detects it and
> leaves the existing Parakeet plist untouched.

**Barge-in:** During TTS playback, the mic is monitored via VAD. If the user starts speaking, playback is interrupted and the system switches to listening. Controlled by `TALK_BARGE_IN` (default: 0 — opt-in, requires `TALK_BARGE_IN=1`). WARNING: requires echo cancellation or careful mic placement — TTS audio bleeding into the mic will trigger false interrupts. Test before enabling.

## Paths

| Role | Path |
|------|------|
| Orchestrator | `~/.config/opencode/skills/talk/talk.sh` |
| VAD engine | `~/.config/opencode/skills/talk/vad_recorder.py` |
| TTS CLI | `~/.config/opencode/tts.sh` |
| Lang / voice presets | `~/.config/opencode/tts_lang.sh` |

## Commands

```bash
~/.config/opencode/skills/talk/talk.sh listen    # block until user stops; print transcript
~/.config/opencode/skills/talk/talk.sh speak "…" # xAI voice iris (no local fallback)
~/.config/opencode/skills/talk/talk.sh status    # health check (all backends)
~/.config/opencode/skills/talk/talk.sh devices   # list mics
~/.config/opencode/skills/talk/talk.sh loop      # continuous loop (tty or pipe stdin)
```

## Talk loop (you orchestrate)

When the user enters talk/voice mode:

1. **First turn only** — `talk.sh listen`. Stdout = first user utterance (may be empty → listen again).
2. **Think** — Reply to that text. Keep answers **short** for voice.
3. **Speak + listen** — `talk.sh speak '<reply>'` (escape single quotes). This plays TTS, plays a short **beep**, and **opens the mic the instant the audio ends** (the recorder is pre-warmed during playback and flipped live by signal — no timing guess, no gap). **Stdout = the user's next utterance** (same as `listen`).
4. **Loop** — Go to step 2 with the text from step 3. **Do not call `listen` separately** after `speak` (it is built in).

The session **persists** across natural pauses and stays open until the user explicitly cancels via one of three signals:

| Signal | Trigger | Empty stdout → agent exits loop |
|--------|---------|--------------------------------|
| Keyboard | `Ctrl+C` / `Cmd+D` (sent to `talk.sh`) | n/a — process killed |
| Session silence | No speech for `TALK_IDLE_TIMEOUT_S` (default 1440s = 24 min) | yes |
| Spoken stop phrase | User says any phrase in `TALK_STOP_PHRASES` (default `"stop talk"`) | yes |

When you receive empty stdout from `talk.sh speak`, **exit the conversation loop** cleanly — the user has ended the session. Do not call `talk.sh listen` again to "recover"; respect the cancel.

### Idle timeout

`listen` exits cleanly with empty stdout after `TALK_IDLE_TIMEOUT_S` seconds (default: **1440** = 24 min) if no speech is detected. This is the **session-silence window**: if the user walks away, the loop ends after 24 min of silence. Set `TALK_IDLE_TIMEOUT_S=0` to disable, or override per-session with e.g. `TALK_IDLE_TIMEOUT_S=1800 talk.sh speak …` for 30 min.

### Stop phrases

`TALK_STOP_PHRASES` is a pipe-separated list of phrases that end the session (case-insensitive substring match). Default: `"stop talk"`. Spanish: `TALK_STOP_PHRASES="stop talk|para de hablar"`. When matched, `cmd_listen` prints `"[talk] Stop phrase detected"` to stderr and empty stdout to the agent.

> **Caveat:** substring match is intentionally permissive — *"I want to stop talking now"* matches `"stop talk"`. For tighter control, use a longer phrase: `TALK_STOP_PHRASES="end the conversation"`. Word-boundary matching is a planned future improvement.

### Rules

- Always invoke `talk.sh` via Shell; never fake transcription or audio.
- **Empty stdout from `speak`** = user ended the session (stop phrase, silence timeout, or keyboard). Exit the conversation loop; do not retry `listen`.
- One-off read-aloud only (no mic): `TALK_AUTO_LISTEN=0 talk.sh speak '…'`.
- TTS down (xAI failed) → check `XAI_API_KEY` and network; do not use macOS `say`, do not switch to local engines.
- First session turn: `talk.sh status` if services were recently restarted.

## Environment

| Variable | Default | Purpose |
|----------|---------|---------|
| `STT_ENGINE` | `local` | STT backend — `local` Parakeet (ONNX, **CPU**) on `:5093` by default; or `remote` (set `STT_REMOTE_URL` + `STT_API_KEY`) for OpenAI Whisper etc. |
| `STT_MODEL` | `parakeet-tdt-0.6b-v3` | Parakeet ONNX/CPU model (same on all platforms) |
| `STT_URL` | `http://127.0.0.1:5093/v1/audio/transcriptions` | Parakeet ONNX endpoint |
| `TTS_ENGINE` | `xai` | TTS backend — xAI cloud (default, voice iris). Local engines (`qwen3-mlx`, `chatterbox-turbo-mlx`, `supertonic`, `qwen`, `neutts`) and remote `openai` remain opt-in via this variable. |
| `QWEN3_MLX_MODEL` | `~/mlx-models/qwen3-tts-12hz-1.7b-base-mlx-8bit` | Explicit local Qwen3-TTS 1.7B W8 checkpoint used by the default route. |
| `QWEN3_MLX_REF_AUDIO_EN` | `~/voices/qwen3-mlx-carina-en.wav` | English reference recording. |
| `QWEN3_MLX_REF_AUDIO_ES` | `~/voices/qwen3-mlx-carina-es.wav` | Spanish reference recording. |
| `QWEN3_MLX_CHUNK_WORDS` | `25` | Sentence-aware chunk ceiling, clamped to 20-30 words. |
| `OPENAI_API_KEY` | (for `openai`) | Bearer key for remote OpenAI-compatible TTS (or `OPENAI_TTS_KEY`); `OPENAI_TTS_URL` sets the base URL |
| `SUPERTONIC_URL` | `http://127.0.0.1:8766` | Supertonic 3 TTS endpoint (auto-installed) |
| `SUPERTONIC_VOICE` | `F4` | Voice style `F1`–`F5` / `M1`–`M5` |
| `TTS_QUALITY` | `normal` | `normal` = 8 steps, `high` = 20 steps; `SUPERTONIC_STEPS=<1-20>` overrides |
| `TTS_FADE_MS` | `6` | Fade-in/out (ms) applied to each TTS clip/chunk to kill onset/offset clicks; `0` disables |
| `QWEN_TTS_QUALITY` | `hq` | Qwen3-TTS server: `fast` (0.6B :18881), `hq` (1.7B :18882), `lazy` (1.7B :18883, auto-start). Server + setup: https://github.com/groxaxo/Qwen3-TTS-Openai-Fastapi |
| `QWEN_TTS_VOICE` | `vivian` | Qwen3-TTS voice (serena, vivian, ryan, aiden, …) |
| `XAI_API_KEY` | (required) | API key for xAI TTS (the default engine) |
| `XAI_TTS_VOICE` | `eve` | xAI voice: `iris`, `ara`, `eve`, `leo`, `rex`, `sal` |
| `TALK_READY_CUE` | 1 | Play a short tone before `listen` |
| `TALK_READY_SOUND` | Tink.aiff | macOS fallback ready sound (used when `TALK_BEEP=0`) |
| `TALK_READY_DELAY_MS` | 700 | Ignore mic after cue (standalone `listen` only) |
| `TALK_BEEP` | `1` | Play a synthesized beep the instant TTS ends, then record immediately (set 0 → fall back to `TALK_READY_SOUND` / bell) |
| `TALK_BEEP_MS` | `150` | Beep duration (ms) |
| `TALK_BEEP_FREQ` | `880` | Beep frequency (Hz) |
| `VAD_THRESHOLD` | 0.5 | Speech sensitivity — lower = catches softer speech; raise toward 0.6–0.7 to ignore background noise / other speakers (single mic, no speaker separation) |
| `VAD_MIN_SILENCE_MS` | 700 | End-of-turn silence (700ms tolerates mid-sentence pauses; lower for snappier turns) |
| `MIC_QUERY` | _(empty)_ | Mic name substring; empty = auto-detect → honors the macOS system-default input (System Settings → Sound → Input), skipping virtual adapters (NoMachine, VirtualBox, VMware) |
| `TALK_AUTO_LISTEN` | `1` | After `speak`, run `listen` |
| `TALK_BARGE_IN` | `0` | Interrupt TTS on speech (opt-in) |
| `TALK_IDLE_TIMEOUT_S` | `1440` | Session-silence window: exit listen if no speech within N seconds (0=disabled, 1440=24 min) |
| `TALK_STOP_PHRASES` | `stop talk` | Pipe-separated phrases that end the session (case-insensitive substring match) |

## Troubleshooting

| Problem | Action |
|---------|--------|
| No transcription | `talk.sh status` — check Parakeet ONNX on `:5093`. macOS: `launchctl kickstart -k gui/$UID/com.opencode.parakeet-stt`. Linux: `systemctl --user start opencode-parakeet-stt`. Windows: `Start-ScheduledTask 'OpenCode-Parakeet-STT'` |
| No TTS | `talk.sh status` — xAI is the default engine; check `XAI_API_KEY` is set and reachable. Local engines are opt-in only (`TTS_ENGINE=<name>`) |
| VAD misses speech | `talk.sh devices`; lower `VAD_THRESHOLD` |
| VAD grabs background speech / TV / others | Raise `VAD_THRESHOLD` toward `0.6`–`0.7` (single mic, no speaker separation — it captures whatever crosses the threshold) |
| Wrong microphone | `talk.sh devices`; set `MIC_QUERY` to your mic name substring |
| No audio on Linux | Install ffmpeg: `sudo apt install ffmpeg` or `sudo dnf install ffmpeg` |
| No audio on Windows | Install ffmpeg: `winget install Gyan.FFmpeg` |
| xAI TTS fails | Check `XAI_API_KEY` is set; `talk.sh status` shows key status |
| Listen blocks forever | Set `TALK_IDLE_TIMEOUT_S` (default 1440s = 24 min); check that mic is working with `talk.sh devices` |
| Want to end the conversation | Speak any phrase in `TALK_STOP_PHRASES` (default `"stop talk"`), wait 24 min in silence, or send `Ctrl+C` to `talk.sh` |
| Agent keeps re-calling `listen` after cancel | Empty stdout from `talk.sh speak` means session ended — break out of the loop, do not retry `listen` |
| All TTS failed | Fix backends; system TTS fallback intentionally not used |
| Backends not running | Rerun `./setup.sh` (macOS/Linux) or `.\setup.ps1` (Windows) |

## Mic-free text bus (agents take turns without the microphone)

Two agents speaking into the same room fight over one microphone: each hears the
other's TTS and transcribes it as if the user had said it. Two fixes are in place.

**1. Global audio lock.** `cmd_speak` takes an exclusive lock (`$TALK_AUDIO_LOCK`,
default `/tmp/talk-audio.lock`) around TTS playback, so a second agent waits its
turn instead of talking over the first. Stale locks are cleared by PID check.
Disable with `TALK_AUDIO_LOCK_DISABLE=1`.

**2. Text bus.** With the mic off, agents exchange turns as timestamped JSON
files instead of audio:

```
$TALK_BUS_DIR/YYYY-MM-DD/<UTCstamp>Z-<agent>.json    # one file per turn
$TALK_BUS_DIR/state/<agent>.read                     # per-agent read marker
```

Each record: `{ts, agent, lang, voice, spoken, text}`. Writes are atomic
(`.tmp` + rename), so a reader never sees a partial message.

| Variable | Default | Effect |
|---|---|---|
| `TALK_MIC` | `on` | `off`/`0`/`no` — never open the microphone |
| `TALK_NO_MIC` | `0` | same as `TALK_MIC=off` |
| `TALK_SILENT` | `0` | `1` — do not play TTS either (fully silent text channel) |
| `TALK_AGENT` | `agent` | author name on the bus (`claudio`, `iris`, `osvaldo`, `constanza`) |
| `TALK_BUS_DIR` | `~/.talk-bus` | bus root |
| `TALK_BUS_TIMEOUT_S` | `TALK_IDLE_TIMEOUT_S` (1440) | how long `wait` blocks |
| `TALK_BUS_POLL_S` | `1` | poll interval |
| `TALK_BUS_REPLAY` | `1` | `0` — a new agent starts from "now" instead of replaying the backlog |
| `TALK_BUS_LOG` | `1` | `0` — do not record outgoing turns on the bus |

Behaviour with the mic off:
- `talk.sh listen` blocks on the bus and prints the other agent's message.
- `talk.sh speak "…"` plays TTS (unless `TALK_SILENT=1`), records the turn on
  the bus, then blocks on the bus for the reply — same stdout contract as before.
- Empty stdout still means "the turn ended" (bus timeout), so the agent loop
  logic is unchanged.

Direct access: `talk.sh bus {post <text> [lang] | read | wait [timeout] | tail [n]}`.

Every outgoing turn is logged to the bus even when the mic is on
(`TALK_BUS_LOG=1`), so an agent joining later can pick up from the last message.


## Sentence-level xAI speech tagging (always on)

Every sentence handed to xAI TTS is first run through
[`groxaxo/xai-sentence-tagger`](https://github.com/groxaxo/xai-sentence-tagger)
(installed at `~/.local/share/xai-sentence-tagger`, wrapper at
`~/.local/bin/xai_tag.sh`), so each sentence carries at least one speech-direction
tag and the voice actually conveys emotion. Tagging happens **per sentence**,
inside the parallel chunk workers, so it costs no extra wall-clock.

| Variable | Default | Effect |
|---|---|---|
| `XAI_TAG` | `1` | `0` disables tagging |
| `XAI_TAG_SH` | `~/.local/bin/xai_tag.sh` | wrapper path |
| `XAI_TAG_COVERAGE` | `natural` | `all` = exhaustive/theatrical |
| `XAI_TAG_LANGUAGE` | `auto` | forced language for the segmenter |
| `XAI_TAG_TIMEOUT` | `20` | seconds before falling back to untagged |

The tagger's LLM is configured in `~/.local/share/xai-sentence-tagger/.env`
(currently xAI `grok-4.20-0309-non-reasoning`). It **fails open**: on timeout,
API error, or any output whose stripped text doesn't match the source exactly,
the original untagged sentence is synthesized instead.

Default voice is **`eve`**.

## Google Gemini voices

`TTS_ENGINE=google` (aliases `gemini`, `google-ai-studio`) synthesizes through
Gemini TTS — 30 prebuilt voices, mono 24 kHz. Pick one with `GEMINI_TTS_VOICE`;
`talk.sh voices` lists every xAI and Google voice with its tone.

```bash
TTS_ENGINE=google GEMINI_TTS_VOICE=Sulafat talk.sh speak '[warmly]Hola.'
```

| Variable | Default | Effect |
|---|---|---|
| `GEMINI_TTS_VOICE` | `Kore` | one of the 30 prebuilt voices |
| `GEMINI_TTS_MODEL` | `gemini-3.1-flash-tts-preview` | TTS model |
| `GEMINI_TTS_STYLE` | *(empty)* | global Director's Notes |
| `GEMINI_API_KEY` / `GOOGLE_API_KEY` | — | credentials; the login keychain entry `GEMINI_API_KEY` is used as a fallback |

Google direction is **English natural-language square brackets** placed at token
boundaries (`[warmly, with quiet confidence] Welcome home.`), not the xAI tag
catalog — the two providers do not share a tag syntax. Contract follows
`docs/GOOGLE_TTS_REFERENCE.md` in `groxaxo/xAI-Voice-Studio`.

## Conversation audio archive (Opus)

Every synthesized utterance and every microphone capture is kept as **Opus**
under a per-conversation subfolder, so a session can be replayed later at a
fraction of WAV's size:

```
$TALK_AUDIO_DIR/<session>/<UTCstamp>-<pid>-spoken-<agent>.opus
$TALK_AUDIO_DIR/<session>/<UTCstamp>-<pid>-heard-user.opus
$TALK_AUDIO_DIR/<session>/conversation.opus        # the merged session
```

For a chunked xAI reply the sentence chunks are concatenated first, so one clip
is one utterance rather than one sentence.

| Variable | Default | Effect |
|---|---|---|
| `TALK_AUDIO_ARCHIVE` | `1` | `0` disables archiving entirely |
| `TALK_AUDIO_DIR` | `~/.talk-audio` | archive root |
| `TALK_SESSION` | `<UTC date>-<agent>` | conversation subfolder name |
| `TALK_AUDIO_BITRATE` | `32k` | Opus bitrate (mono, 48 kHz) |

`talk.sh archive-merge [dir]` concatenates a session's clips in timestamp order
into `conversation.opus`. It runs automatically when a stop phrase ends the
session; run it by hand for a session that ended some other way. Requires
`ffmpeg`; archiving silently no-ops without it.
