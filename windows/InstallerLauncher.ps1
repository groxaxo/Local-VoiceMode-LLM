#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$payload = Join-Path $env:TEMP 'LocalVoiceModeLLM\payload.zip'
$bundleDir = Join-Path $env:LOCALAPPDATA 'LocalVoiceModeLLM'

if (-not (Test-Path $payload)) {
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show('The bundled installer payload was not found. Download a fresh installer.', 'Local VoiceMode Installer') | Out-Null
    exit 1
}

New-Item -ItemType Directory -Force -Path $bundleDir | Out-Null
Expand-Archive -Path $payload -DestinationPath $bundleDir -Force
$manager = Join-Path $bundleDir 'windows\VoiceModeManager.ps1'
if (-not (Test-Path $manager)) { throw "Bundled manager was not found at $manager" }

& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $manager -Installer
