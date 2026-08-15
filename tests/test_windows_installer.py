from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "setup.ps1"
TALK = ROOT / "windows" / "talk.ps1"
MANAGER = ROOT / "windows" / "VoiceModeManager.ps1"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_windows_entrypoints_are_ascii_safe_for_powershell_51() -> None:
    for path in (SETUP, TALK, MANAGER):
        text = read(path)
        assert text.isascii(), f"{path.relative_to(ROOT)} must remain ASCII-safe"


def test_installer_has_component_and_integration_selectors() -> None:
    setup = read(SETUP)
    for parameter in (
        "$SkipParakeet",
        "$SkipSupertonic",
        "$VenvOnly",
        "$Integrations",
        "$NoIntegrations",
    ):
        assert parameter in setup
    for integration in ("claudecode", "opencode", "openclaw", "hermes", "codex"):
        assert integration in setup


def test_installer_registers_local_cpu_services() -> None:
    setup = read(SETUP)
    assert "OpenCode-Parakeet-STT" in setup
    assert "OpenCode-Supertonic" in setup
    assert "New-ScheduledTaskTrigger -AtLogOn" in setup
    assert "-RestartCount 99" in setup
    assert "PARAKEET_USE_GPU = 'false'" in setup
    assert "SUPERTONIC_ORT_BACKEND = 'cpu'" in setup
    assert "--host 127.0.0.1" in setup
    assert "http://127.0.0.1:$ParakeetPort/health" in setup
    assert "http://127.0.0.1:$SupertonicPort/health" in setup
    assert "ConvertFrom-Json" in setup
    assert "Stop-ScheduledTask -TaskName $Name" in setup


def test_installer_checks_windows_native_prerequisites_and_failures() -> None:
    setup = read(SETUP)
    assert "Python 3.11 or newer is required" in setup
    assert "Microsoft.VCRedist.2015+.x64" in setup
    assert "$LASTEXITCODE -ne 0" in setup
    assert "import onnxruntime" in setup


def test_manager_delegates_installation_and_manages_health() -> None:
    manager = read(MANAGER)
    assert "setup.ps1" in manager
    assert "Start-Installer" in manager
    assert "Install / Repair" in manager
    assert "Get-ScheduledTask" in manager
    assert "Start-ScheduledTask" in manager
    assert "Stop-ScheduledTask" in manager
    assert "Invoke-WebRequest" in manager
    assert "Initializing" in manager
    assert "windows-services.json" in manager
    assert "systemctl" not in manager
    assert "git clone" not in manager
    assert "pip install" not in manager


def test_windows_talk_uses_non_conflicting_text_parameter_and_api_shape() -> None:
    talk = read(TALK)
    assert "$TextArgs" in talk
    assert "[string[]]$Args" not in talk
    assert "input = $Text" in talk
    assert "response_format = \"wav\"" in talk
    assert "Invoke-WebRequest -Uri \"$SupertonicUrl/v1/audio/speech\"" in talk


def test_release_build_embeds_the_branded_payload() -> None:
    build = read(ROOT / "windows" / "build-release.ps1")
    assert "Invoke-ps2exe" in build
    assert "LocalVoiceModeInstaller.exe" in build
    assert "LocalVoiceModeManager.exe" in build
    assert "Compress-Archive" in build
    assert "voicemode-logo.ico" in build
    assert (ROOT / "windows" / "assets" / "voicemode-logo.svg").exists()
