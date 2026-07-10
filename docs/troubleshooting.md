# Troubleshooting runbook

Use this guide from the top down. Most failures are caused by one of four things:

1. The microphone or playback device is unavailable.
2. A backend service is stopped.
3. The orchestrator points at a different port than the running service.
4. The launching shell did not inherit the intended environment variables.

## 1. Confirm the installed command

On macOS or Linux:

```bash
TALK="$HOME/.config/opencode/skills/talk/talk.sh"
ls -l "$TALK"
"$TALK" status
```

On Windows:

```powershell
$Talk = "$env:USERPROFILE\.config\opencode\skills\talk\talk.ps1"
Get-Item $Talk
& $Talk status
```

When an agent behaves differently from a terminal test, verify that the agent is invoking the installed copy rather than a stale checkout or an older skill directory.

## 2. Verify the effective environment

The installer runs Supertonic 3 on port `8766`, while a manually installed or older backend may use `8765`. Set the endpoint explicitly in the shell that launches the agent:

```bash
export STT_URL=http://127.0.0.1:5093/v1/audio/transcriptions
export STT_MODEL=parakeet-tdt-0.6b-v3
export SUPERTONIC_URL=http://127.0.0.1:8766
export TTS_ENGINE=supertonic
```

Inspect relevant variables:

```bash
env | grep -E '^(STT|TTS|SUPERTONIC|VAD|MIC|TALK|OPENAI|INWORLD|XAI)_' | sort
```

PowerShell:

```powershell
Get-ChildItem Env: | Where-Object Name -Match '^(STT|TTS|SUPERTONIC|VAD|MIC|TALK|OPENAI|INWORLD|XAI)_'
```

A repository `.env` file is not automatically loaded by Bash, Zsh, PowerShell, or the agent. Source/export it deliberately or configure the process manager that launches the agent.

## 3. Test backend endpoints directly

### Parakeet STT

Check whether the service is listening:

```bash
curl -fsS http://127.0.0.1:5093/health || \
  curl -sS -o /dev/null -w '%{http_code}\n' \
  -X OPTIONS http://127.0.0.1:5093/v1/audio/transcriptions
```

A backend may not expose `/health`; the transcription request is the definitive test.

### Supertonic TTS

```bash
curl -fsS http://127.0.0.1:8766/health
```

Generate a short WAV without the talk loop:

```bash
SUPERTONIC_URL=http://127.0.0.1:8766 \
TTS_ENGINE=supertonic \
TTS_NO_PLAY=1 \
~/.config/opencode/tts.sh "Backend test"
```

The command should print a path to a non-empty WAV file.

## 4. Service recovery

### macOS

```bash
launchctl kickstart -k gui/$UID/com.opencode.parakeet-stt
launchctl kickstart -k gui/$UID/com.opencode.supertonic

tail -n 100 ~/.config/opencode/parakeet-stt.log
tail -n 100 ~/.config/opencode/supertonic.log
```

Inspect loaded services:

```bash
launchctl print gui/$UID/com.opencode.parakeet-stt
launchctl print gui/$UID/com.opencode.supertonic
```

### Linux

```bash
systemctl --user daemon-reload
systemctl --user restart opencode-parakeet-stt
systemctl --user restart opencode-supertonic

systemctl --user --no-pager --full status opencode-parakeet-stt
systemctl --user --no-pager --full status opencode-supertonic

journalctl --user -u opencode-parakeet-stt -n 100 --no-pager
journalctl --user -u opencode-supertonic -n 100 --no-pager
```

If `systemctl --user` cannot connect, confirm that a user session and D-Bus user bus are available. In containers, minimal WSL environments, or SSH-only sessions, run the backend commands manually or enable lingering for the user where appropriate.

### Windows

```powershell
Start-ScheduledTask "OpenCode-Parakeet-STT"
Start-ScheduledTask "OpenCode-Supertonic"
Start-Sleep -Seconds 3

Get-ScheduledTask "OpenCode-Parakeet-STT", "OpenCode-Supertonic" |
  Select-Object TaskName, State

Get-Content "$env:USERPROFILE\.config\opencode\parakeet-stt.log" -Tail 100
Get-Content "$env:USERPROFILE\.config\opencode\supertonic.log" -Tail 100
```

## 5. Microphone diagnosis

List and inspect devices:

```bash
talk.sh devices
talk.sh list-mics
talk.sh pick
```

Use an explicit name substring for a one-off test:

```bash
MIC_QUERY="Headset" talk.sh listen
```

An explicit query that does not match a usable input device should be treated as a configuration error. Run `talk.sh devices` and copy a distinctive portion of the actual name.

### macOS permissions

Grant microphone access to the terminal or agent host in:

```text
System Settings → Privacy & Security → Microphone
```

Restart the terminal/agent after changing permission.

### Linux audio access

Check device visibility:

```bash
arecord -l 2>/dev/null || true
pactl list short sources 2>/dev/null || true
python3 -c 'import sounddevice as sd; print(sd.query_devices())'
```

For remote SSH or container sessions, the host microphone is usually not available unless audio devices and the sound server are passed through explicitly.

### Windows permissions

Check:

```text
Settings → Privacy & security → Microphone
```

Allow microphone access for desktop applications, then restart PowerShell or the agent.

## 6. VAD and endpointing

Use explicit values while diagnosing so platform defaults do not obscure the result:

```bash
VAD_THRESHOLD=0.5 \
VAD_MIN_SILENCE_MS=700 \
TALK_IDLE_TIMEOUT_S=60 \
talk.sh listen
```

| Symptom | Adjustment |
|---|---|
| Speech is never detected | Lower `VAD_THRESHOLD` toward `0.3`–`0.4`; verify the selected microphone and input level |
| Background speech or television triggers recording | Raise `VAD_THRESHOLD` toward `0.6`–`0.7`; use headphones or move the microphone closer |
| The turn ends during natural pauses | Raise `VAD_MIN_SILENCE_MS` to `900`–`1500` |
| The response feels slow after speaking stops | Lower `VAD_MIN_SILENCE_MS` toward `500`–`700` |
| The start of speech is clipped | Raise pre-speech padding through the dashboard or `vad_recorder.py --pre-speech-ms` |
| Listen exits without a transcript | Increase `TALK_IDLE_TIMEOUT_S`; inspect microphone permissions and VAD output |
| Barge-in triggers on the assistant's own audio | Disable `TALK_BARGE_IN`, use headphones, or add acoustic echo cancellation outside this project |

A single microphone cannot identify who is speaking. Threshold tuning reduces false triggers but is not speaker separation.

## 7. Playback diagnosis

### macOS

```bash
afplay /System/Library/Sounds/Tink.aiff
```

### Linux

Try the installed player directly:

```bash
command -v ffplay aplay paplay cvlc mpv
ffplay -nodisp -autoexit -loglevel quiet /path/to/test.wav
```

Install an option if none is available:

```bash
sudo apt install ffmpeg
# or
sudo dnf install ffmpeg
```

### Windows

```powershell
Get-Command ffplay -ErrorAction SilentlyContinue
```

The built-in fallback supports WAV. Install ffmpeg when testing other formats or when SoundPlayer is unavailable.

## 8. STT returns an error or empty text

Capture the HTTP response directly:

```bash
curl -sS -D /tmp/parakeet-headers.txt \
  -o /tmp/parakeet-response.json \
  http://127.0.0.1:5093/v1/audio/transcriptions \
  -F 'file=@/path/to/test.wav' \
  -F 'model=parakeet-tdt-0.6b-v3'

cat /tmp/parakeet-headers.txt
cat /tmp/parakeet-response.json
```

Check:

- The file is a non-empty, readable audio file.
- The model id matches the running backend.
- The server completed its first model download/load.
- A proxy is not intercepting localhost requests.
- A remote endpoint has the required bearer token.

For remote STT:

```bash
export STT_ENGINE=remote
export STT_REMOTE_URL=https://provider.example/v1/audio/transcriptions
export STT_REMOTE_MODEL=whisper-1
export STT_API_KEY=...
```

Remote STT selection is implemented by the Unix orchestrator. Confirm feature parity before relying on the PowerShell path.

## 9. TTS engine diagnosis

Force one engine at a time rather than testing the entire fallback chain:

```bash
TALK_AUTO_LISTEN=0 \
TTS_ENGINE=supertonic \
SUPERTONIC_URL=http://127.0.0.1:8766 \
talk.sh speak "Testing Supertonic"
```

For the optional Supertonic 2 service on `:8880`:

```bash
TALK_AUTO_LISTEN=0 \
TTS_ENGINE=supertonic \
SUPERTONIC_URL=http://127.0.0.1:8880 \
talk.sh speak "Testing Supertonic two"
```

The current dispatcher does not expose a separate `supertonic2` alias; use the Supertonic-compatible endpoint override above.

### Remote provider failures

- **OpenAI-compatible:** verify `OPENAI_TTS_URL`, `OPENAI_TTS_KEY` or `OPENAI_API_KEY`, model id, voice id, and that the endpoint accepts `/audio/speech`.
- **Inworld:** the credential must be the expected Basic/base64 API key. HTTP `401` or `403` is surfaced as a configuration failure rather than silently changing voices.
- **xAI:** verify `XAI_API_KEY`, current account access, and provider availability.

Never paste live API keys into issue reports or logs.

## 10. Dashboard issues

Start it from the repository:

```bash
cd frontend
bash start.sh
```

Then open `http://127.0.0.1:7862`.

The browser UI proxies requests to the URLs configured for the dashboard server. Check its terminal output and backend status badges.

The **Apply & Restart** compute controls write Linux `systemd --user` overrides. They are not a portable service manager for macOS or Windows. On those platforms, manage launchd or Task Scheduler directly.

## 11. Agent loop problems

### Agent calls `listen` twice

`talk.sh speak` already invokes the next listen when `TALK_AUTO_LISTEN=1`. The correct loop is:

```text
listen once → agent reply → speak → use speak stdout as next user turn
```

### Agent restarts after the user ended the session

Empty stdout from `talk.sh speak` is the session-end signal. Stop the loop; do not call `listen` again.

### Quoting breaks long replies

Pass reply text as one safely quoted shell argument. For complex text, write it to a temporary file and use shell-safe command construction rather than interpolating untrusted text into a command string.

## 12. Clean repair

First try a normal idempotent setup:

```bash
cd Local-VoiceMode-LLM
git pull --ff-only
./setup.sh --cpu
```

```powershell
cd Local-VoiceMode-LLM
git pull --ff-only
.\setup.ps1
```

Use force mode only when a managed service definition is known to be stale and any local customization has been backed up:

```bash
./setup.sh --cpu --force
```

```powershell
.\setup.ps1 -Force
```

For a complete reinstall, uninstall destructively and rerun setup. This removes downloaded environments and models and therefore requires downloading them again.
