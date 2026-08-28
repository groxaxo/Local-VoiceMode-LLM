#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Local VoiceMode LLM on Windows.
.DESCRIPTION
    Installs the local CPU speech stack, registers per-user startup tasks, and
    copies the talk skill to selected agent integrations.
#>
[CmdletBinding()]
param(
    [switch]$SkipParakeet,
    [switch]$SkipSupertonic,
    [switch]$SkipVoices,
    [switch]$VenvOnly,
    [switch]$Force,
    [switch]$Uninstall,
    [switch]$NoIntegrations,
    [string]$Integrations = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = $PSScriptRoot
$ConfigDir = Join-Path $env:USERPROFILE '.config\opencode'
$SkillDir = Join-Path $ConfigDir 'skills\talk'
$VenvDir = Join-Path $ConfigDir 'tts-venv'
$ParakeetDir = Join-Path $ConfigDir 'parakeet-stt'
$SupertonicDir = Join-Path $ConfigDir 'supertonic-tts'
$ParakeetPort = if ($env:PARAKEET_PORT) { $env:PARAKEET_PORT } else { '5093' }
$SupertonicPort = if ($env:SUPERTONIC_PORT) { $env:SUPERTONIC_PORT } else { '8766' }

$AgentTargets = @{
    claudecode = Join-Path $env:USERPROFILE '.claude\skills\talk'
    opencode = $SkillDir
    openclaw = Join-Path $env:USERPROFILE '.openclaw\skills\talk'
    hermes = Join-Path $env:USERPROFILE '.hermes\skills\talk'
    codex = Join-Path $env:USERPROFILE '.codex\skills\talk'
}

function Write-Info { param([string]$Message) Write-Host "[setup] $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "[setup] OK: $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[setup] WARNING: $Message" -ForegroundColor Yellow }

function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments)
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$FilePath failed with exit code $LASTEXITCODE" }
}

function ConvertTo-PowerShellLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-PythonCommand {
    $command = Get-Command python -ErrorAction SilentlyContinue
    if (-not $command) { throw 'Python was not found. Install Python 3.12 with: winget install --id Python.Python.3.12' }
    $versionText = & $command.Source -c 'import sys; print(sys.version_info[0],sys.version_info[1])'
    if ($LASTEXITCODE -ne 0 -or -not $versionText) { throw 'The python command is not a working Python installation.' }
    $parts = $versionText.Trim().Split(' ')
    if ([int]$parts[0] -lt 3 -or ([int]$parts[0] -eq 3 -and [int]$parts[1] -lt 11)) {
        throw "Python 3.11 or newer is required; found $($parts -join '.')."
    }
    Write-Info "Python $($parts -join '.')"
    return $command.Source
}

function Test-VcRuntime {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    )
    foreach ($key in $keys) {
        $runtime = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($runtime -and $runtime.Installed -eq 1) { return $true }
    }
    return $false
}

function New-PythonEnvironment {
    param([string]$Python, [string]$Path)
    if (-not (Test-Path (Join-Path $Path 'Scripts\python.exe'))) {
        Invoke-Native $Python @('-m', 'venv', $Path) | Out-Null
    }
    $venvPython = Join-Path $Path 'Scripts\python.exe'
    Invoke-Native $venvPython @('-m', 'pip', 'install', '--quiet', '--upgrade', 'pip', 'setuptools', 'wheel') | Out-Null
    return $venvPython
}

function Register-VoiceTask {
    param(
        [string]$Name,
        [string]$Script,
        [string]$WorkingDirectory,
        [string]$Description
    )
    $existing = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if ($existing -and -not $Force) {
        Write-Warn "Task '$Name' already exists; use -Force to replace it."
        return
    }
    if ($existing) {
        Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
        $deadline = (Get-Date).AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 250
            $existing = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
        } while ($existing -and $existing.State -eq 'Running' -and (Get-Date) -lt $deadline)
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false
    }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File `"$Script`"" -WorkingDirectory $WorkingDirectory
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger -Settings $settings -Description $Description -Force | Out-Null
    Write-Ok "Registered startup task $Name"
}

function Wait-Endpoint {
    param([string]$Name, [string]$Url, [int]$TimeoutSeconds = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3
            $body = $response.Content | ConvertFrom-Json
            $ready = if ($body.PSObject.Properties.Name -contains 'ready') {
                [bool]$body.ready
            } elseif ($body.PSObject.Properties.Name -contains 'model_loaded') {
                [bool]$body.model_loaded
            } else {
                $body.status -eq 'healthy'
            }
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300 -and $ready) {
                Write-Ok "$Name is healthy at $Url"
                return $true
            }
        } catch {}
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    Write-Warn "$Name did not become healthy within $TimeoutSeconds seconds. Check its log under $ConfigDir."
    return $false
}

function Remove-VoiceMode {
    foreach ($name in 'OpenCode-Parakeet-STT', 'OpenCode-Supertonic') {
        $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($task) {
            Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            Write-Ok "Removed task $name"
        }
    }
    if ($Force) {
        foreach ($path in $ParakeetDir, $SupertonicDir, $VenvDir, $SkillDir) {
            if (Test-Path $path) { Remove-Item $path -Recurse -Force }
        }
        Write-Ok 'Removed managed installation directories.'
    } else {
        Write-Info "Downloaded models and environments were retained in $ConfigDir."
    }
}

if ($Uninstall) { Remove-VoiceMode; exit 0 }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git was not found. Install it with: winget install --id Git.Git'
}
$Python = Get-PythonCommand
if (-not (Test-VcRuntime)) {
    throw 'Microsoft Visual C++ x64 Runtime is required. Install it with: winget install --id Microsoft.VCRedist.2015+.x64'
}

New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
Write-Info 'Installing voice core environment...'
$VenvPython = New-PythonEnvironment $Python $VenvDir
Invoke-Native $VenvPython @('-m', 'pip', 'install', '--quiet', 'silero-vad', 'sounddevice', 'onnxruntime', 'torch', 'torchaudio', 'numpy')
Write-Ok 'Voice core installed.'
if ($VenvOnly) { exit 0 }

$installedTasks = New-Object System.Collections.Generic.List[string]

if (-not $SkipParakeet) {
    Write-Info 'Installing local Parakeet STT...'
    if (Test-Path (Join-Path $ParakeetDir '.git')) {
        Invoke-Native git @('-C', $ParakeetDir, 'pull', '--ff-only')
    } else {
        if (Test-Path $ParakeetDir) { Remove-Item $ParakeetDir -Recurse -Force }
        Invoke-Native git @('clone', 'https://github.com/groxaxo/parakeet-tdt-0.6b-v3-fastapi-openai', $ParakeetDir)
    }
    $parakeetVenv = Join-Path $ParakeetDir '.venv'
    $parakeetPython = New-PythonEnvironment $Python $parakeetVenv
    $requirements = Join-Path $ParakeetDir 'requirements-windows.txt'
    (Get-Content (Join-Path $ParakeetDir 'requirements.txt')) -replace 'onnxruntime-gpu[^\r\n]*', 'onnxruntime' | Set-Content $requirements -Encoding UTF8
    Invoke-Native $parakeetPython @('-m', 'pip', 'install', '--quiet', '-r', $requirements)
    Invoke-Native $parakeetPython @('-c', 'import onnxruntime; print(onnxruntime.__version__)')
    $wrapper = Join-Path $ParakeetDir 'start-windows.ps1'
    $lines = @(
        "`$env:PARAKEET_PORT = $(ConvertTo-PowerShellLiteral $ParakeetPort)",
        "`$env:PARAKEET_USE_GPU = 'false'",
        "`$env:PARAKEET_BATCHED = '0'",
        "`$env:PYTHONUNBUFFERED = '1'",
        "& $(ConvertTo-PowerShellLiteral $parakeetPython) $(ConvertTo-PowerShellLiteral (Join-Path $ParakeetDir 'server.py')) *>> $(ConvertTo-PowerShellLiteral (Join-Path $ConfigDir 'parakeet-stt.log'))",
        'exit $LASTEXITCODE'
    )
    Set-Content $wrapper $lines -Encoding UTF8
    Register-VoiceTask 'OpenCode-Parakeet-STT' $wrapper $ParakeetDir "Parakeet ONNX STT on 127.0.0.1:$ParakeetPort"
    $installedTasks.Add('OpenCode-Parakeet-STT')
}

if (-not $SkipSupertonic) {
    Write-Info 'Installing local Supertonic TTS...'
    if (Test-Path (Join-Path $SupertonicDir '.git')) {
        Invoke-Native git @('-C', $SupertonicDir, 'pull', '--ff-only')
    } else {
        if (Test-Path $SupertonicDir) { Remove-Item $SupertonicDir -Recurse -Force }
        Invoke-Native git @('clone', 'https://github.com/groxaxo/supertonic-express-3', $SupertonicDir)
    }
    $supertonicVenv = Join-Path $SupertonicDir '.venv'
    $supertonicPython = New-PythonEnvironment $Python $supertonicVenv
    Invoke-Native $supertonicPython @('-m', 'pip', 'install', '--quiet', '-r', (Join-Path $SupertonicDir 'py\requirements.txt'))
    Invoke-Native $supertonicPython @('-c', 'import onnxruntime; print(onnxruntime.__version__)')

    $modelDir = Join-Path $SupertonicDir 'assets\supertonic-3'
    $onnxDir = Join-Path $modelDir 'onnx'
    $voiceDir = Join-Path $modelDir 'voice_styles'
    $modelFiles = 'duration_predictor.onnx', 'text_encoder.onnx', 'vector_estimator.onnx', 'vocoder.onnx'
    $modelReady = $true
    foreach ($file in $modelFiles) {
        $path = Join-Path $onnxDir $file
        if (-not (Test-Path $path) -or (Get-Item $path).Length -lt 1000000) { $modelReady = $false }
    }
    if (-not $modelReady -or -not (Test-Path (Join-Path $onnxDir 'tts.json'))) {
        New-Item -ItemType Directory -Force -Path $onnxDir, $voiceDir | Out-Null
        $media = 'https://media.githubusercontent.com/media/groxaxo/supertonic-3-v2/main'
        $raw = 'https://raw.githubusercontent.com/groxaxo/supertonic-3-v2/main'
        foreach ($file in $modelFiles) { Invoke-WebRequest -Uri "$media/onnx/$file" -OutFile (Join-Path $onnxDir $file) -UseBasicParsing }
        foreach ($file in 'tts.json', 'unicode_indexer.json') { Invoke-WebRequest -Uri "$raw/onnx/$file" -OutFile (Join-Path $onnxDir $file) -UseBasicParsing }
        foreach ($voice in 'F1', 'F2', 'F3', 'F4', 'F5', 'M1', 'M2', 'M3', 'M4', 'M5') {
            Invoke-WebRequest -Uri "$raw/voice_styles/$voice.json" -OutFile (Join-Path $voiceDir "$voice.json") -UseBasicParsing
        }
    }
    if ($SkipVoices) { Write-Warn '-SkipVoices is retained for compatibility; bundled Supertonic style files are still required.' }
    $wrapper = Join-Path $SupertonicDir 'start-windows.ps1'
    $lines = @(
        "`$env:SUPERTONIC_MODEL_DIR = $(ConvertTo-PowerShellLiteral $modelDir)",
        "`$env:ONNX_DIR = $(ConvertTo-PowerShellLiteral $onnxDir)",
        "`$env:VOICE_STYLES_DIR = $(ConvertTo-PowerShellLiteral $voiceDir)",
        "`$env:USE_GPU = 'false'",
        "`$env:SUPERTONIC_ORT_BACKEND = 'cpu'",
        "`$env:PYTHONUNBUFFERED = '1'",
        "Set-Location $(ConvertTo-PowerShellLiteral (Join-Path $SupertonicDir 'py'))",
        "& $(ConvertTo-PowerShellLiteral $supertonicPython) -m uvicorn api.src.main:app --host 127.0.0.1 --port $SupertonicPort --app-dir $(ConvertTo-PowerShellLiteral (Join-Path $SupertonicDir 'py')) *>> $(ConvertTo-PowerShellLiteral (Join-Path $ConfigDir 'supertonic.log'))",
        'exit $LASTEXITCODE'
    )
    Set-Content $wrapper $lines -Encoding UTF8
    Register-VoiceTask 'OpenCode-Supertonic' $wrapper (Join-Path $SupertonicDir 'py') "Supertonic ONNX TTS on 127.0.0.1:$SupertonicPort"
    $installedTasks.Add('OpenCode-Supertonic')
}

$serviceSettings = [ordered]@{
    parakeet_health_url = "http://127.0.0.1:$ParakeetPort/health"
    supertonic_health_url = "http://127.0.0.1:$SupertonicPort/health"
}
$serviceSettings | ConvertTo-Json | Set-Content (Join-Path $ConfigDir 'windows-services.json') -Encoding UTF8

Write-Info 'Installing talk skill...'
New-Item -ItemType Directory -Force -Path $SkillDir | Out-Null
foreach ($file in 'service\vad_recorder.py', 'service\talk.sh', 'service\tts.sh', 'service\tts_lang.sh', 'windows\talk.ps1', 'skill\SKILL.md') {
    Copy-Item (Join-Path $RepoDir $file) $SkillDir -Force
}
Copy-Item (Join-Path $RepoDir 'service\tts.sh') (Join-Path $ConfigDir 'tts.sh') -Force
Copy-Item (Join-Path $RepoDir 'service\tts_lang.sh') (Join-Path $ConfigDir 'tts_lang.sh') -Force
Copy-Item (Join-Path $RepoDir 'windows\talk.ps1') (Join-Path $ConfigDir 'talk.ps1') -Force

$selected = New-Object System.Collections.Generic.List[string]
if (-not $NoIntegrations) {
    if ($Integrations) {
        foreach ($name in $Integrations.Split(',')) {
            $key = $name.Trim().ToLowerInvariant()
            if (-not $AgentTargets.ContainsKey($key)) { throw "Unknown integration '$key'." }
            $selected.Add($key)
        }
    } elseif ([Environment]::UserInteractive) {
        foreach ($key in $AgentTargets.Keys | Sort-Object) {
            $answer = Read-Host "Install the talk skill for $key? [Y/n]"
            if (-not $answer -or $answer -match '^[Yy]') { $selected.Add($key) }
        }
    }
}
foreach ($key in $selected) {
    $target = $AgentTargets[$key]
    if ([IO.Path]::GetFullPath($target) -eq [IO.Path]::GetFullPath($SkillDir)) { continue }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item (Join-Path $SkillDir '*') $target -Recurse -Force
    Write-Ok "Installed $key integration."
}

foreach ($taskName in $installedTasks) {
    Start-ScheduledTask -TaskName $taskName
    Write-Info "Started $taskName"
}
if (-not $SkipParakeet) { [void](Wait-Endpoint 'Parakeet STT' "http://127.0.0.1:$ParakeetPort/health") }
if (-not $SkipSupertonic) { [void](Wait-Endpoint 'Supertonic TTS' "http://127.0.0.1:$SupertonicPort/health") }

Write-Host ''
Write-Ok 'Windows setup finished.'
Write-Host "Talk command: & '$SkillDir\talk.ps1' status"
Write-Host "Manager app:  & '$RepoDir\windows\VoiceModeManager.ps1'"
