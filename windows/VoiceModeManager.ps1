#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Installer)

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Installer) { $arguments += ' -Installer' }
    Start-Process powershell.exe -ArgumentList $arguments
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$repoDir = Split-Path $PSScriptRoot -Parent
$setupScript = Join-Path $repoDir 'setup.ps1'
$configDir = Join-Path $env:USERPROFILE '.config\opencode'
$talkScript = Join-Path $configDir 'skills\talk\talk.ps1'
$settingsPath = Join-Path $configDir 'windows-services.json'
$parakeetHealthUrl = 'http://127.0.0.1:5093/health'
$supertonicHealthUrl = 'http://127.0.0.1:8766/health'
if (Test-Path $settingsPath) {
    try {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($settings.parakeet_health_url) { $parakeetHealthUrl = $settings.parakeet_health_url }
        if ($settings.supertonic_health_url) { $supertonicHealthUrl = $settings.supertonic_health_url }
    } catch {}
}

$services = @{
    Parakeet = @{
        Task = 'OpenCode-Parakeet-STT'
        Url = $parakeetHealthUrl
        Log = Join-Path $configDir 'parakeet-stt.log'
        Folder = Join-Path $configDir 'parakeet-stt'
    }
    Supertonic = @{
        Task = 'OpenCode-Supertonic'
        Url = $supertonicHealthUrl
        Log = Join-Path $configDir 'supertonic.log'
        Folder = Join-Path $configDir 'supertonic-tts'
    }
}

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 300, [int]$Height = 24)
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object Drawing.Point($X, $Y)
    $label.Size = New-Object Drawing.Size($Width, $Height)
    return $label
}

function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 105)
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object Drawing.Point($X, $Y)
    $button.Size = New-Object Drawing.Size($Width, 32)
    return $button
}

function New-CheckBox {
    param([string]$Text, [int]$X, [int]$Y, [bool]$Checked = $true)
    $box = New-Object Windows.Forms.CheckBox
    $box.Text = $Text
    $box.Location = New-Object Drawing.Point($X, $Y)
    $box.Size = New-Object Drawing.Size(220, 25)
    $box.Checked = $Checked
    return $box
}

function Get-EndpointHealth {
    param([string]$Url)
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
        $body = $response.Content | ConvertFrom-Json
        $ready = if ($body.PSObject.Properties.Name -contains 'ready') {
            [bool]$body.ready
        } elseif ($body.PSObject.Properties.Name -contains 'model_loaded') {
            [bool]$body.model_loaded
        } else {
            $body.status -eq 'healthy'
        }
        return if ($ready) { 'Healthy' } else { 'Initializing' }
    } catch {
        return 'Offline'
    }
}

function Get-ServiceDescription {
    param([hashtable]$Service)
    $task = Get-ScheduledTask -TaskName $Service.Task -ErrorAction SilentlyContinue
    $taskState = if ($task) { [string]$task.State } else { 'Not registered' }
    $health = Get-EndpointHealth $Service.Url
    return "$taskState | $health | $($Service.Url)"
}

function Invoke-TaskAction {
    param([string]$Key, [string]$Action)
    $name = $services[$Key].Task
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if (-not $task) {
        [Windows.Forms.MessageBox]::Show("$name is not installed.", 'Local VoiceMode LLM') | Out-Null
        return
    }
    switch ($Action) {
        Start { Start-ScheduledTask -TaskName $name }
        Stop { Stop-ScheduledTask -TaskName $name }
        Restart {
            Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 300
            Start-ScheduledTask -TaskName $name
        }
    }
    Start-Sleep -Milliseconds 500
    Update-ServiceStatus
}

function Start-Installer {
    param([string[]]$Arguments)
    if (-not (Test-Path $setupScript)) {
        [Windows.Forms.MessageBox]::Show("setup.ps1 was not found at $setupScript", 'Local VoiceMode LLM') | Out-Null
        return
    }
    $quotedSetup = '"' + $setupScript + '"'
    $argumentLine = "-NoProfile -ExecutionPolicy Bypass -File $quotedSetup " + ($Arguments -join ' ')
    Start-Process powershell.exe -ArgumentList $argumentLine -WorkingDirectory $repoDir
}

$form = New-Object Windows.Forms.Form
$form.Text = if ($Installer) { 'Local VoiceMode Installer' } else { 'Local VoiceMode LLM' }
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object Drawing.Size(790, 590)
$form.MinimumSize = New-Object Drawing.Size(806, 629)
$form.Font = New-Object Drawing.Font('Segoe UI', 9)
$form.BackColor = [Drawing.Color]::FromArgb(246, 247, 249)
$iconPath = Join-Path $PSScriptRoot 'assets\voicemode-logo.ico'
if (Test-Path $iconPath) { $form.Icon = New-Object Drawing.Icon($iconPath) }

$title = New-Label 'LOCAL VOICEMODE' 22 14 520 34
$title.Font = New-Object Drawing.Font('Segoe UI Semibold', 18)
$subtitle = New-Label 'Private Parakeet speech recognition and Supertonic speech synthesis' 24 50 680 24
$subtitle.ForeColor = [Drawing.Color]::FromArgb(80, 85, 95)
$form.Controls.AddRange(@($title, $subtitle))

$tabs = New-Object Windows.Forms.TabControl
$tabs.Location = New-Object Drawing.Point(20, 84)
$tabs.Size = New-Object Drawing.Size(750, 480)
$form.Controls.Add($tabs)

$setupTab = New-Object Windows.Forms.TabPage
$setupTab.Text = 'Install'
$setupTab.BackColor = [Drawing.Color]::White
$tabs.TabPages.Add($setupTab)

$setupTab.Controls.Add((New-Label 'Speech components' 24 20 300 25))
$core = New-CheckBox 'Voice core and Silero VAD (required)' 28 50
$core.Enabled = $false
$parakeet = New-CheckBox 'Parakeet STT (local CPU)' 28 80
$supertonic = New-CheckBox 'Supertonic TTS (local CPU)' 28 110
$setupTab.Controls.AddRange(@($core, $parakeet, $supertonic))

$setupTab.Controls.Add((New-Label 'Agent integrations' 390 20 300 25))
$integrationBoxes = @{}
$top = 80
foreach ($entry in @(
    @{ Key = 'claudecode'; Text = 'Claude Code'; Checked = $false },
    @{ Key = 'codex'; Text = 'Codex'; Checked = $false },
    @{ Key = 'openclaw'; Text = 'OpenClaw'; Checked = $false },
    @{ Key = 'hermes'; Text = 'Hermes'; Checked = $false }
)) {
    $box = New-CheckBox $entry.Text 394 $top $entry.Checked
    $integrationBoxes[$entry.Key] = $box
    $setupTab.Controls.Add($box)
    $top += 30
}
$opencodeIntegration = New-CheckBox 'OpenCode (canonical skill, required)' 394 50
$opencodeIntegration.Enabled = $false
$setupTab.Controls.Add($opencodeIntegration)

$pathLabel = New-Label "Install root: $configDir" 28 230 680 25
$pathLabel.ForeColor = [Drawing.Color]::FromArgb(80, 85, 95)
$setupTab.Controls.Add($pathLabel)

$install = New-Button 'Install / Repair' 28 275 145
$install.BackColor = [Drawing.Color]::FromArgb(28, 92, 170)
$install.ForeColor = [Drawing.Color]::White
$install.FlatStyle = 'Flat'
$install.Add_Click({
    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add('-Force')
    if (-not $parakeet.Checked) { $arguments.Add('-SkipParakeet') }
    if (-not $supertonic.Checked) { $arguments.Add('-SkipSupertonic') }
    $selected = @($integrationBoxes.Keys | Where-Object { $integrationBoxes[$_].Checked })
    if ($selected.Count -eq 0) {
        $arguments.Add('-NoIntegrations')
    } else {
        $arguments.Add('-Integrations')
        $arguments.Add(('"' + ($selected -join ',') + '"'))
    }
    Start-Installer $arguments
})

$removeTasks = New-Button 'Remove startup' 188 275 135
$removeTasks.Add_Click({ Start-Installer @('-Uninstall') })
$removeAll = New-Button 'Remove all...' 338 275 125
$removeAll.Add_Click({
    $answer = [Windows.Forms.MessageBox]::Show('Remove tasks, models, environments, and the OpenCode talk skill?', 'Confirm removal', 'YesNo', 'Warning')
    if ($answer -eq 'Yes') { Start-Installer @('-Uninstall', '-Force') }
})
$setupTab.Controls.AddRange(@($install, $removeTasks, $removeAll))
$setupTab.Controls.Add((New-Label 'Installation runs in a separate PowerShell window so downloads and errors remain visible.' 28 325 670 45))

$servicesTab = New-Object Windows.Forms.TabPage
$servicesTab.Text = 'Services'
$servicesTab.BackColor = [Drawing.Color]::White
$tabs.TabPages.Add($servicesTab)

$statusLabels = @{}
$rowY = 35
foreach ($key in 'Parakeet', 'Supertonic') {
    $heading = New-Label $key 26 $rowY 150 28
    $heading.Font = New-Object Drawing.Font('Segoe UI Semibold', 12)
    $status = New-Label 'Checking...' 165 ($rowY + 3) 530 25
    $statusLabels[$key] = $status
    $start = New-Button 'Start' 26 ($rowY + 38) 90
    $stop = New-Button 'Stop' 126 ($rowY + 38) 90
    $restart = New-Button 'Restart' 226 ($rowY + 38) 90
    $folder = New-Button 'Open folder' 326 ($rowY + 38) 105
    $log = New-Button 'Open log' 441 ($rowY + 38) 105
    $start.Add_Click({ Invoke-TaskAction $this.Tag 'Start' }.GetNewClosure()); $start.Tag = $key
    $stop.Add_Click({ Invoke-TaskAction $this.Tag 'Stop' }.GetNewClosure()); $stop.Tag = $key
    $restart.Add_Click({ Invoke-TaskAction $this.Tag 'Restart' }.GetNewClosure()); $restart.Tag = $key
    $folder.Add_Click({ if (Test-Path $services[$this.Tag].Folder) { Start-Process explorer.exe $services[$this.Tag].Folder } }.GetNewClosure()); $folder.Tag = $key
    $log.Add_Click({ if (Test-Path $services[$this.Tag].Log) { Start-Process notepad.exe $services[$this.Tag].Log } }.GetNewClosure()); $log.Tag = $key
    $servicesTab.Controls.AddRange(@($heading, $status, $start, $stop, $restart, $folder, $log))
    $rowY += 145
}
$refresh = New-Button 'Refresh health' 26 340 125
$refresh.Add_Click({ Update-ServiceStatus })
$servicesTab.Controls.Add($refresh)

function Update-ServiceStatus {
    foreach ($key in $statusLabels.Keys) {
        $description = Get-ServiceDescription $services[$key]
        $statusLabels[$key].Text = $description
        $statusLabels[$key].ForeColor = if ($description -match 'Healthy') { [Drawing.Color]::ForestGreen } elseif ($description -match 'Initializing') { [Drawing.Color]::DarkGoldenrod } else { [Drawing.Color]::Firebrick }
    }
}

$diagnosticsTab = New-Object Windows.Forms.TabPage
$diagnosticsTab.Text = 'Diagnostics'
$diagnosticsTab.BackColor = [Drawing.Color]::White
$tabs.TabPages.Add($diagnosticsTab)

$diagnostics = New-Object Windows.Forms.TextBox
$diagnostics.Location = New-Object Drawing.Point(24, 70)
$diagnostics.Size = New-Object Drawing.Size(690, 330)
$diagnostics.Multiline = $true
$diagnostics.ReadOnly = $true
$diagnostics.ScrollBars = 'Both'
$diagnostics.Font = New-Object Drawing.Font('Consolas', 9)
$diagnosticsTab.Controls.Add($diagnostics)

function Invoke-TalkDiagnostic {
    param([string]$Command)
    if (-not (Test-Path $talkScript)) {
        $diagnostics.Text = "Talk skill is not installed at $talkScript"
        return
    }
    $diagnostics.Text = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $talkScript $Command 2>&1 | Out-String)
}

$runStatus = New-Button 'Run status' 24 22 105
$runStatus.Add_Click({ Invoke-TalkDiagnostic 'status' })
$devices = New-Button 'Microphones' 139 22 105
$devices.Add_Click({ Invoke-TalkDiagnostic 'devices' })
$copy = New-Button 'Copy output' 254 22 105
$copy.Add_Click({ if ($diagnostics.Text) { [Windows.Forms.Clipboard]::SetText($diagnostics.Text) } })
$diagnosticsTab.Controls.AddRange(@($runStatus, $devices, $copy))

$tabs.Add_SelectedIndexChanged({ if ($tabs.SelectedTab -eq $servicesTab) { Update-ServiceStatus } })
$form.Add_Shown({ Update-ServiceStatus })
[void]$form.ShowDialog()
