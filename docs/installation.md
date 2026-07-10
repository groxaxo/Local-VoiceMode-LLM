# Installation and service management

This guide covers supported installation paths, flags, service names, verification, upgrades, and removal.

## Requirements

### macOS

- Git
- Python 3.11 or newer; Python 3.12 is preferred
- Command Line Tools or another working compiler toolchain for packages that need native components
- An accessible microphone
- `afplay` is included with macOS
- `ffmpeg` is recommended for utility conversions used by optional paths

Homebrew examples:

```bash
brew install git python@3.12 ffmpeg
```

### Linux

- Git
- Python 3.11 or newer; Python 3.12 is preferred
- PortAudio development/runtime support for `sounddevice`
- An audio player: `ffplay`, `aplay`, `paplay`, `cvlc`, or `mpv`
- A user systemd session for automatic backend startup

Ubuntu/Debian example:

```bash
sudo apt update
sudo apt install -y git python3 python3-venv python3-pip portaudio19-dev ffmpeg
```

Fedora example:

```bash
sudo dnf install -y git python3 python3-pip portaudio-devel ffmpeg
```

### Windows

- Windows PowerShell 5.1 or newer
- Git
- Python 3.11 or newer; Python 3.12 is preferred
- `ffplay` is recommended, although the PowerShell orchestrator can use `System.Media.SoundPlayer` for WAV playback

```powershell
winget install --id Git.Git
winget install --id Python.Python.3.12
winget install --id Gyan.FFmpeg
```

## macOS and Linux

```bash
git clone https://github.com/groxaxo/Local-VoiceMode-LLM.git
cd Local-VoiceMode-LLM
chmod +x setup.sh
./setup.sh
```

When run in an interactive terminal with no arguments, the installer asks which backends and agent integrations to install.

### Installer flags

| Flag | Effect |
|---|---|
| `--skip-parakeet` | Do not install the local Parakeet STT backend |
| `--skip-supertonic` | Do not install the local Supertonic TTS backend |
| `--venv-only` | Create only the shared voice environment |
| `--skip-voices` | Skip optional reference-voice generation |
| `--gpu` | Use CUDA when an NVIDIA GPU is available; Linux only |
| `--cpu` | Force CPU execution |
| `--integrations=...` | Install only the named comma-separated integrations |
| `--no-integrations` | Do not install agent skills |
| `--force` / `-f` | Replace existing managed service definitions |
| `--uninstall` | Stop/remove managed service definitions while retaining backend directories |
| `--uninstall --force` | Also remove managed installation directories |

Valid integration identifiers:

```text
claudecode,opencode,openclaw,hermes,codex
```

Examples:

```bash
./setup.sh --cpu --integrations=claudecode,opencode
./setup.sh --skip-supertonic --no-integrations
./setup.sh --uninstall
./setup.sh --uninstall --force
```

### Accelerator behavior

- **Linux + NVIDIA:** interactive setup offers CUDA but defaults to CPU so VRAM remains available to the LLM. `--gpu` selects CUDA non-interactively.
- **Linux without NVIDIA:** CPU ONNX Runtime.
- **macOS:** CPU ONNX is the main installer path. Optional CoreML services are separate from the default setup.
- **Windows:** the main PowerShell installer uses CPU ONNX Runtime.

## Windows

```powershell
git clone https://github.com/groxaxo/Local-VoiceMode-LLM.git
cd Local-VoiceMode-LLM
.\setup.ps1
```

### PowerShell parameters

| Parameter | Effect |
|---|---|
| `-SkipParakeet` | Skip local STT installation |
| `-SkipSupertonic` | Skip local TTS installation |
| `-SkipVoices` | Skip reference voice generation |
| `-VenvOnly` | Create only the voice environment |
| `-Integrations "..."` | Install a comma-separated subset of agent integrations |
| `-Force` | Replace existing managed scheduled tasks |
| `-Uninstall` | Remove managed tasks while keeping installation directories |
| `-Uninstall -Force` | Also remove managed directories |

Examples:

```powershell
.\setup.ps1 -Integrations "claudecode,opencode"
.\setup.ps1 -SkipSupertonic
.\setup.ps1 -Uninstall
.\setup.ps1 -Uninstall -Force
```

## Installed paths

Unix paths use `$HOME`; Windows uses the equivalent location under `$env:USERPROFILE`.

| Component | Path |
|---|---|
| Shared voice environment | `~/.config/opencode/tts-venv/` |
| Parakeet checkout and environment | `~/.config/opencode/parakeet-stt/` |
| Supertonic checkout and environment | `~/.config/opencode/supertonic-tts/` |
| Canonical OpenCode skill | `~/.config/opencode/skills/talk/` |
| TTS wrapper | `~/.config/opencode/tts.sh` |
| Language helper | `~/.config/opencode/tts_lang.sh` |
| Saved microphone selection | `~/.config/opencode/talk-mic.env` |
| Dashboard configuration | `~/.config/opencode/frontend-config.json` |

Agent-specific skill paths:

| Agent | Path |
|---|---|
| Claude Code | `~/.claude/skills/talk/` |
| OpenCode | `~/.config/opencode/skills/talk/` |
| OpenClaw | `~/.openclaw/skills/talk/` |
| Hermes | `~/.hermes/skills/talk/` |
| Codex | `~/.codex/skills/talk/` |

## Ports

| Service | Default port |
|---|---:|
| Parakeet STT | `5093` |
| Supertonic 3 TTS | `8766` |
| Optional Supertonic 2 TTS | `8880` |
| Dashboard | `7862` |
| Ollama | `11434` |

The project deliberately uses `8766` for Supertonic 3 so it can coexist with software already using `8765`.

## Post-install environment

Export the backend endpoints in the same shell/session that launches the agent:

```bash
export STT_URL=http://127.0.0.1:5093/v1/audio/transcriptions
export STT_MODEL=parakeet-tdt-0.6b-v3
export SUPERTONIC_URL=http://127.0.0.1:8766
export TTS_ENGINE=supertonic
```

A `.env` file is only a template unless your shell, process manager, or launcher explicitly loads it.

## Verification

### Unix

```bash
TALK="$HOME/.config/opencode/skills/talk/talk.sh"

"$TALK" status
"$TALK" devices
TALK_AUTO_LISTEN=0 "$TALK" speak "The local voice stack is ready."
"$TALK" listen
```

### Windows

```powershell
$Talk = "$env:USERPROFILE\.config\opencode\skills\talk\talk.ps1"

& $Talk status
& $Talk devices
$env:TALK_AUTO_LISTEN = "0"
& $Talk speak "The local voice stack is ready."
```

## Service management

### macOS launchd

```bash
launchctl kickstart -k gui/$UID/com.opencode.parakeet-stt
launchctl kickstart -k gui/$UID/com.opencode.supertonic

launchctl bootout gui/$UID/com.opencode.parakeet-stt
launchctl bootout gui/$UID/com.opencode.supertonic

tail -f ~/.config/opencode/parakeet-stt.log
tail -f ~/.config/opencode/supertonic.log
```

### Linux systemd user services

```bash
systemctl --user status opencode-parakeet-stt
systemctl --user status opencode-supertonic

systemctl --user restart opencode-parakeet-stt
systemctl --user restart opencode-supertonic

journalctl --user -u opencode-parakeet-stt -f
journalctl --user -u opencode-supertonic -f
```

### Windows Task Scheduler

```powershell
Get-ScheduledTask "OpenCode-Parakeet-STT", "OpenCode-Supertonic"
Start-ScheduledTask "OpenCode-Parakeet-STT"
Start-ScheduledTask "OpenCode-Supertonic"
Stop-ScheduledTask "OpenCode-Parakeet-STT"
Stop-ScheduledTask "OpenCode-Supertonic"

Get-Content "$env:USERPROFILE\.config\opencode\parakeet-stt.log" -Tail 100
Get-Content "$env:USERPROFILE\.config\opencode\supertonic.log" -Tail 100
```

## Upgrading

Update the repository and rerun setup:

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

The installer updates backend checkouts and resynchronizes skill files. Existing service definitions are preserved unless force mode is selected.

## Uninstalling

A normal uninstall removes managed startup definitions but keeps model directories and environments, avoiding a large re-download if you reinstall later.

```bash
./setup.sh --uninstall
./setup.sh --uninstall --force   # destructive cleanup
```

```powershell
.\setup.ps1 -Uninstall
.\setup.ps1 -Uninstall -Force   # destructive cleanup
```

Review retained paths before deleting them manually, especially if they contain custom models, service overrides, or voice assets.
