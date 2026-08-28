# Architecture reference

## Scope

Local VoiceMode LLM is a speech orchestration layer, not an LLM server. It owns microphone capture, endpointing, transcription, synthesis, playback, and the contract used by supported AI agents.

The core runtime is intentionally split into independently replaceable stages:

```text
VAD → STT → agent/LLM → TTS → playback
```

The default deployment keeps VAD, STT, and TTS local. Optional remote providers replace only the selected speech stage.

## System overview

```text
┌──────────────┐
│ Microphone   │
└──────┬───────┘
       │ 16 kHz mono float32
       ▼
┌──────────────────────────────┐
│ service/vad_recorder.py      │
│ sounddevice + Silero VAD     │
│ bounded absolute ring buffer │
└──────────────┬───────────────┘
               │ normalized PCM WAV
               ▼
┌──────────────────────────────┐
│ Parakeet STT                 │
│ OpenAI-compatible multipart  │
│ default: 127.0.0.1:5093      │
└──────────────┬───────────────┘
               │ transcript
               ▼
┌──────────────────────────────┐
│ Agent or local LLM           │
│ Claude Code / OpenCode /     │
│ OpenClaw / Hermes / Codex /  │
│ Ollama integration           │
└──────────────┬───────────────┘
               │ reply text
               ▼
┌──────────────────────────────┐
│ service/tts.sh               │
│ engine selection + fallback  │
└──────────────┬───────────────┘
               │ WAV / streamed chunks
               ▼
┌──────────────────────────────┐
│ Platform playback            │
│ afplay / ffplay / aplay /    │
│ paplay / SoundPlayer         │
└──────────────┬───────────────┘
               │
               └──────────────► next microphone turn
```

## Runtime components

| Component | Responsibility |
|---|---|
| `service/vad_recorder.py` | Device selection, capture, Silero VAD, endpointing, bounded buffering, normalization, WAV output |
| `service/talk.sh` | Unix orchestration, STT routing, TTS invocation, ready cues, auto-listen, stop phrases, optional barge-in |
| `windows/talk.ps1` | Windows orchestration and local backend use |
| `service/tts.sh` | Unix TTS engine implementations and fallback dispatch |
| `service/tts_lang.sh` | Lightweight language selection and normalization |
| `service/inworld_steer.sh` | Optional expressive delivery-tag generation for Inworld |
| `skill/SKILL.md` | Agent-facing protocol for entering and maintaining a voice conversation |
| `frontend/server.py` | Local dashboard proxy, configuration persistence, status checks, Linux service controls |
| `integrations/ollama/ollama-voice` | Ollama HTTP chat loop with streamed text and sentence-level TTS scheduling |

## VAD recorder

### Input format

The recorder opens one `sounddevice.InputStream` with:

- 16,000 Hz sample rate
- one input channel
- `float32` samples
- two VAD frames per callback block

Silero consumes frames of 512 samples, approximately 32 ms each.

```text
InputStream callback
      │
      ├── frame 0: 512 samples ─► ring buffer ─► Silero
      └── frame 1: 512 samples ─► ring buffer ─► Silero
```

### Absolute ring-buffer coordinates

`RingBuffer` tracks two quantities:

- total samples appended since the most recent clear
- samples still retained after capacity eviction

From those values:

```text
first_sample = total_appended - retained_samples
end_sample   = total_appended
```

Evicting old frames reduces retained samples but never moves the absolute end coordinate backward. This is important because Silero emits sample offsets relative to its current state, while the recorder may reset that state after a ready-delay window.

Slices are clamped to the retained interval:

```text
[first_sample, end_sample)
```

That protects long recordings and prevents stale coordinates from creating empty or shifted utterances.

### VAD coordinate offset

During pre-warmed listening, the recorder captures audio while ignoring VAD decisions. When it becomes live, it resets Silero and records an offset equal to the current absolute frame position. Later `start` and `end` events are translated into recorder coordinates by adding that offset once.

The max-duration path already operates in absolute ring-buffer coordinates and therefore uses `ring.end_sample` directly.

### Turn finalization

When Silero reports an end event, or the maximum duration is reached:

1. Subtract pre-speech padding from the detected start.
2. Clamp the start to the first retained sample.
3. Slice the ring buffer through the absolute end sample.
4. Reject events shorter than 100 ms.
5. Normalize toward -20 dBFS, capped at 4× gain and a 0.98 ceiling.
6. Write mono, 16-bit PCM WAV at 16 kHz.
7. Emit a JSON-line `speech_end` event.
8. Reset VAD state and sample coordinates for the next turn.

Example recorder protocol:

```json
{"event":"listening","timestamp":0.0}
{"event":"speech_end","timestamp":0.0,"file":"/tmp/opencode-turn-...wav","duration_ms":2450}
```

Other terminal events include `idle_timeout`, `barge_in`, and `error`.

### Device selection

When no explicit query is supplied, selection prefers:

1. The operating-system default input when it is usable.
2. On macOS, a built-in MacBook microphone as a legacy fallback.
3. The first acceptable physical input.
4. As a final fallback, any input device.

Known virtual/remote adapters are skipped in the preferred paths. When `--mic-query` is supplied, failure to match returns no device rather than silently choosing an unrelated microphone.

## STT boundary

The Unix orchestrator resolves one URL and model pair per transcription:

```text
local:
  STT_URL + STT_MODEL

remote:
  STT_REMOTE_URL + STT_REMOTE_MODEL
```

The request shape is:

```http
POST /v1/audio/transcriptions
Content-Type: multipart/form-data

file=<wav>
model=<model id>
```

A bearer token is included only when the resolved `STT_API_KEY` is non-empty.

The managed local service is Parakeet on:

```text
http://127.0.0.1:5093/v1/audio/transcriptions
```

The PowerShell orchestrator uses `STT_URL` and `STT_MODEL` directly and does not currently mirror every Unix remote-routing feature.

## Unix conversation orchestration

### First turn

```text
talk.sh listen
  ├── start recorder
  ├── play ready cue
  ├── wait for speech_end or timeout
  ├── POST WAV to STT
  └── print transcript to stdout
```

Stdout is reserved for the transcript so an agent can consume it directly. Diagnostics go to stderr.

### Speak and auto-listen

With `TALK_AUTO_LISTEN=1`, `talk.sh speak` uses a pre-record path:

1. Ask `tts.sh` to synthesize without playing and return a WAV path.
2. Start the recorder with a long ignore window so model loading and microphone opening overlap playback.
3. Play the generated reply.
4. Play the ready beep.
5. Send `SIGUSR1` to activate the recorder immediately on Unix platforms that support it.
6. Wait for the next utterance.
7. Transcribe it and print it to stdout.

```text
TTS generation ───────► WAV
                         │
recorder preload ────────┼──► playback ─► beep ─► SIGUSR1 ─► live VAD
                         │                                  │
                         └──────────────────────────────────┘
```

A ready-delay remains as a safety fallback if signal activation is unavailable.

### Session termination

The agent must interpret empty stdout from `speak` as a clean end-of-session signal. Empty output can result from:

- idle timeout
- a configured spoken stop phrase
- no completed utterance

The agent must not automatically call `listen` again after that signal.

### Barge-in

When enabled, TTS is generated to a WAV and played in the background while a separate VAD recorder watches for speech. If VAD triggers first, playback is terminated.

This is acoustic detection, not echo cancellation. Speaker bleed can trigger false interruption.

## TTS dispatcher

`service/tts.sh` implements provider-specific request functions behind a shared contract:

```text
input:  reply text + language hint + environment
output: playback side effect, or a WAV path when TTS_NO_PLAY=1
```

Supported dispatcher values are:

```text
supertonic
qwen
qwen-lazy
neutts
inflect
openai
inworld
xai
```

The exact fallback graph is documented in [`providers.md`](providers.md). The optional Supertonic 2 service exposes a compatible endpoint but currently has no separate dispatcher alias; it is selected by overriding `SUPERTONIC_URL` while using `TTS_ENGINE=supertonic`.

### Chunked remote playback

OpenAI-compatible, Inworld, and xAI paths can split normal playback on sentence boundaries. Requests run concurrently, but completed chunks are played in original order.

```text
sentence 0 ─► request ─► chunk 0 ─┐
sentence 1 ─► request ─► chunk 1 ─┼─► ordered playback
sentence 2 ─► request ─► chunk 2 ─┘
```

When the orchestrator needs one file for pre-warmed playback or barge-in, provider paths use or assemble a single WAV rather than returning multiple chunk paths.

### Click reduction

TTS WAVs can receive a short edge fade controlled by `TTS_FADE_MS`. This is especially useful for independently synthesized sentence chunks whose first sample may not start at zero amplitude.

## Windows architecture

Windows uses the same installed Python recorder and backend services but a PowerShell orchestration layer:

```text
windows/talk.ps1
  ├── Start-Process vad_recorder.py
  ├── parse JSON-line output
  ├── curl.exe to Parakeet
  ├── invoke configured TTS wrapper
  └── ffplay or SoundPlayer
```

Automatic startup is provided by Task Scheduler rather than launchd or systemd. The Windows path is intentionally treated as its own implementation; provider routing and advanced Unix signal behavior should not be assumed to be identical.

## Agent integration model

The installer creates one canonical OpenCode skill and copies it into the selected agent directories. Each copy contains the scripts needed to run the protocol locally.

```text
setup
  └── ~/.config/opencode/skills/talk/
        ├── SKILL.md
        ├── talk.sh
        ├── talk.ps1
        ├── tts.sh
        ├── tts_lang.sh
        └── vad_recorder.py

then copied to selected agent skill directories
```

The skill contract tells the agent to:

- invoke the real shell command rather than simulate audio
- use `listen` only for the initial turn
- use `speak` stdout for subsequent turns
- keep spoken answers concise
- exit cleanly on empty stdout

## Dashboard

The dashboard is a static page served through a FastAPI proxy on `:7862`:

```text
Browser :7862
    │
    ▼
frontend/server.py
    ├── /api/tts    ─► Supertonic endpoint
    ├── /api/stt    ─► Parakeet endpoint
    ├── /api/status ─► backend health checks
    └── /api/config ─► frontend-config.json
```

Configuration is stored at:

```text
~/.config/opencode/frontend-config.json
```

The compute-toggle restart implementation writes `systemd --user` drop-ins. Therefore:

- synthesis/transcription tests are portable when the URLs are reachable
- Linux service restart controls are systemd-specific
- macOS and Windows services must be managed through launchd or Task Scheduler

## Process and service boundaries

| Platform | STT startup | TTS startup | Playback |
|---|---|---|---|
| macOS | launchd | launchd | `afplay` |
| Linux | `systemd --user` | `systemd --user` | `ffplay`, `aplay`, `paplay`, `cvlc`, or `mpv` |
| Windows | Task Scheduler | Task Scheduler | `ffplay` or SoundPlayer |

Default managed ports:

| Component | Port |
|---|---:|
| Parakeet STT | `5093` |
| Supertonic 3 TTS | `8766` |
| Supertonic 2 optional service | `8880` |
| Dashboard | `7862` |
| Ollama integration target | `11434` |

## Configuration ownership

Configuration enters the runtime through several layers:

1. Shell/process environment
2. Defaults declared in the orchestrator or provider script
3. Saved microphone file used by `talk.sh`
4. Dashboard JSON for dashboard-managed VAD/backend values
5. Service-manager environment in launchd, systemd, or Task Scheduler

These layers are not automatically synchronized. For predictable operation, export critical endpoint and latency values in the environment that launches the agent:

```bash
export STT_URL=http://127.0.0.1:5093/v1/audio/transcriptions
export SUPERTONIC_URL=http://127.0.0.1:8766
export TTS_QUALITY=normal
export VAD_MIN_SILENCE_MS=700
```

## Failure model

| Failure | Expected behavior |
|---|---|
| No microphone | recorder emits an error and exits non-zero |
| Explicit microphone query has no match | selection fails instead of choosing another device |
| Idle without speech | recorder emits `idle_timeout`; talk loop returns empty stdout |
| Tiny VAD event | event is discarded and VAD/sample state is reset |
| STT HTTP error | orchestrator reports failure and does not fabricate text |
| Primary TTS failure | dispatcher follows the selected engine's explicit fallback chain |
| Inworld auth rejection | Unix dispatcher exits with a configuration error rather than silently changing voice |
| No audio player | playback reports a missing-player error |
| Agent receives empty stdout | agent should end the conversation loop |

## Testing boundary

Repository CI performs:

- Python compilation
- unit tests for ring-buffer coordinates and slicing
- shell syntax validation

CI does not provide a physical microphone, speaker, platform service manager, model download, or live provider credentials. Release validation should still include manual smoke tests on each supported operating system.
