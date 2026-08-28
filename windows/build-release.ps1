#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Version = '1.0.0',
    [switch]$InstallBuildTools
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoDir = Split-Path $PSScriptRoot -Parent
$assetsDir = Join-Path $PSScriptRoot 'assets'
$releaseDir = Join-Path $repoDir 'dist\windows'
$buildDir = Join-Path $repoDir 'build\windows-release'
$iconPath = Join-Path $assetsDir 'voicemode-logo.ico'
$payloadPath = Join-Path $buildDir 'LocalVoiceModeLLM-payload.zip'

function New-VoiceModeIcon {
    param([string]$Path)
    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object Drawing.Bitmap 256, 256
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([Drawing.Color]::FromArgb(11, 16, 32))
    $orb = [Drawing.Drawing2D.LinearGradientBrush]::new(
        [Drawing.Rectangle]::new(26, 26, 204, 204),
        [Drawing.Color]::FromArgb(76, 201, 240),
        [Drawing.Color]::FromArgb(36, 19, 93),
        45
    )
    $graphics.FillEllipse($orb, 35, 35, 186, 186)
    $ring = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(95, 139, 233, 253)), 2
    $graphics.DrawEllipse($ring, 53, 53, 150, 150)
    $signal = New-Object Drawing.Pen ([Drawing.Color]::White), 9
    $signal.StartCap = [Drawing.Drawing2D.LineCap]::Round
    $signal.EndCap = [Drawing.Drawing2D.LineCap]::Round
    $points = [Drawing.Point[]]@(
        [Drawing.Point]::new(55, 129), [Drawing.Point]::new(78, 98),
        [Drawing.Point]::new(102, 158), [Drawing.Point]::new(128, 80),
        [Drawing.Point]::new(153, 158), [Drawing.Point]::new(178, 98),
        [Drawing.Point]::new(201, 129)
    )
    $graphics.DrawLines($signal, $points)
    $microphone = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(11, 16, 32)), 10
    $graphics.DrawLine($microphone, 128, 163, 128, 202)
    $graphics.DrawLine($microphone, 104, 202, 152, 202)
    $graphics.Dispose()
    $handle = $bitmap.GetHicon()
    $icon = [Drawing.Icon]::FromHandle($handle)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Create)
    try { $icon.Save($stream) } finally { $stream.Dispose(); $icon.Dispose(); $bitmap.Dispose() }
}

if (-not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) {
    if (-not $InstallBuildTools) {
        throw 'PS2EXE is required. Run: .\windows\build-release.ps1 -InstallBuildTools'
    }
    Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
    Import-Module ps2exe -Force
}

New-Item -ItemType Directory -Force -Path $assetsDir, $releaseDir, $buildDir | Out-Null
New-VoiceModeIcon $iconPath
Remove-Item $payloadPath -Force -ErrorAction SilentlyContinue

$payloadItems = Get-ChildItem -LiteralPath $repoDir -Force | Where-Object {
    $_.Name -notin '.git', 'dist', 'build', '.pytest_cache', '__pycache__'
}
Compress-Archive -Path $payloadItems.FullName -DestinationPath $payloadPath -CompressionLevel Optimal

$embeddedPayload = @{ '%TEMP%\LocalVoiceModeLLM\payload.zip' = $payloadPath }
$common = @{
    x64 = $true
    STA = $true
    noConsole = $true
    iconFile = $iconPath
    embedFiles = $embeddedPayload
    company = 'groxaxo'
    product = 'Local VoiceMode LLM'
    copyright = 'MIT License'
    version = $Version
    DPIAware = $true
    winFormsDPIAware = $true
}

Invoke-ps2exe -inputFile (Join-Path $PSScriptRoot 'InstallerLauncher.ps1') -outputFile (Join-Path $releaseDir 'LocalVoiceModeInstaller.exe') -title 'Local VoiceMode Installer' -description 'Installs and repairs local Parakeet and Supertonic voice services.' @common
Invoke-ps2exe -inputFile (Join-Path $PSScriptRoot 'ManagerLauncher.ps1') -outputFile (Join-Path $releaseDir 'LocalVoiceModeManager.exe') -title 'Local VoiceMode Manager' -description 'Manages local Parakeet and Supertonic voice services.' @common

Get-ChildItem $releaseDir -Filter '*.exe' | Select-Object Name, Length, LastWriteTime
