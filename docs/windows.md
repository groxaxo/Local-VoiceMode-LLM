# Windows installer and manager

The supported Windows path runs Silero VAD, Parakeet STT, and Supertonic TTS locally on the CPU. The backend APIs listen only on `127.0.0.1` and start through per-user Task Scheduler tasks. Administrator access is not required for the project installation or tasks.

![Local VoiceMode LLM logo](../windows/assets/voicemode-logo.svg)

## Prerequisites

Run these commands in PowerShell:

```powershell
winget install --id Git.Git
winget install --id Python.Python.3.12
winget install --id Microsoft.VCRedist.2015+.x64
winget install --id Gyan.FFmpeg
```

The Visual C++ x64 runtime is required by ONNX Runtime. FFmpeg is recommended for audio playback and conversion.

Open a new PowerShell window after installing Python so its updated `PATH` is available.

## Graphical installer

The repository includes prebuilt native launchers:

```text
dist\windows\LocalVoiceModeInstaller.exe
dist\windows\LocalVoiceModeManager.exe
```

Both executables include the current repository payload, expand it into `%LOCALAPPDATA%\LocalVoiceModeLLM`, and start the native manager. The installer opens the **Install** tab; the manager is for later service checks and repair. They do not need administrator access.

Clone the repository and open the native Windows manager:

```powershell
git clone https://github.com/groxaxo/Local-VoiceMode-LLM.git
cd Local-VoiceMode-LLM
.\windows\VoiceModeManager.ps1
```

If script execution is restricted, launch it explicitly with:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\windows\VoiceModeManager.ps1
```

The **Install** tab selects:

- required voice core and Silero VAD
- local Parakeet STT
- local Supertonic TTS
- OpenCode, Claude Code, Codex, OpenClaw, and Hermes integrations

**Install / Repair** opens a separate PowerShell console so model-download progress and errors remain visible. Repair mode refreshes backend checkouts, Python packages, startup scripts, and scheduled tasks without deleting downloaded models.

The **Services** tab independently reports Task Scheduler state and HTTP endpoint health. It can start, stop, or restart each backend and open its installation folder or log.

The **Diagnostics** tab runs the installed `talk.ps1 status` and `talk.ps1 devices` commands.

## Build the executables

The checked-in executables are reproducible from the repository. The build uses the CurrentUser PowerShell `PS2EXE` module only as a packaging tool:

```powershell
.\windows\build-release.ps1 -InstallBuildTools
```

It regenerates the icon at `windows\assets\voicemode-logo.ico`, creates a compressed source payload, and writes the two executables plus their DPI configuration files to `dist\windows`.

## Command-line installer

Install the default local stack interactively:

```powershell
.\setup.ps1
```

Install for OpenCode without prompts:

```powershell
.\setup.ps1 -Integrations "opencode"
```

Other useful selections:

```powershell
.\setup.ps1 -SkipParakeet -Integrations "opencode"
.\setup.ps1 -SkipSupertonic -NoIntegrations
.\setup.ps1 -VenvOnly
.\setup.ps1 -Force -Integrations "opencode,claudecode"
```

`-Force` stops active managed tasks before replacing their definitions. It does not delete models during installation. `-NoIntegrations` skips optional agent-specific copies, but the canonical OpenCode skill is always installed because it supplies the shared Windows voice command. `-Uninstall -Force` is destructive and removes managed model, environment, and OpenCode skill directories.

## Installed services

| Component | Task | Endpoint | Log |
|---|---|---|---|
| Parakeet STT | `OpenCode-Parakeet-STT` | `http://127.0.0.1:5093` | `~/.config/opencode/parakeet-stt.log` |
| Supertonic TTS | `OpenCode-Supertonic` | `http://127.0.0.1:8766` | `~/.config/opencode/supertonic.log` |

The first Parakeet start can take longer while its model is downloaded and initialized.

## Verification

```powershell
$Talk = "$env:USERPROFILE\.config\opencode\skills\talk\talk.ps1"
& $Talk status
& $Talk devices

Invoke-WebRequest http://127.0.0.1:5093/health -UseBasicParsing
Invoke-WebRequest http://127.0.0.1:8766/health -UseBasicParsing
```

Test local speech synthesis without reopening the microphone:

```powershell
$env:TALK_AUTO_LISTEN = '0'
& $Talk speak 'The local Windows voice stack is ready.'
```

## Removal

Remove only startup tasks and retain models for a later reinstall:

```powershell
.\setup.ps1 -Uninstall
```

Remove managed tasks, backends, environments, and the OpenCode talk skill:

```powershell
.\setup.ps1 -Uninstall -Force
```

## Windows fixes in this installer

The Windows implementation deliberately:

- uses ASCII-safe PowerShell entry points so Windows PowerShell 5.1 does not misread BOM-less UTF-8 punctuation as quote delimiters
- checks Python 3.11 or newer and the Visual C++ x64 runtime before installing ONNX packages
- checks native command exit codes instead of reporting success after failed `git`, Python, or pip commands
- replaces GPU ONNX Runtime requirements with CPU ONNX Runtime for Parakeet
- validates ONNX imports before registering services
- binds both backend APIs to localhost rather than all network interfaces
- safely quotes generated startup-script paths
- propagates backend exit codes so Task Scheduler restart settings work
- verifies backend HTTP health after starting tasks
- avoids copying the OpenCode skill directory onto itself

Windows uses CPU ONNX Runtime in the primary installer. CUDA selection and the dashboard's `systemd` controls remain Linux-specific.
