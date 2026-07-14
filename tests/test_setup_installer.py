from __future__ import annotations

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "scripts" / "install.sh"
MODULE_DIR = ROOT / "scripts" / "install.d"


def installer_text() -> str:
    parts = [INSTALLER.read_text(encoding="utf-8")]
    parts.extend(path.read_text(encoding="utf-8") for path in sorted(MODULE_DIR.glob("*.sh")))
    return "\n".join(parts)


SUPERTONIC_PLIST = ROOT / "launchd" / "com.opencode.supertonic.plist"
PARAKEET_PLIST = ROOT / "launchd" / "com.opencode.parakeet-stt.plist"


def test_shell_entrypoints_parse_and_help() -> None:
    for script in (ROOT / "setup.sh", INSTALLER, ROOT / "service" / "doctor.sh"):
        subprocess.run(["bash", "-n", str(script)], check=True)
    help_result = subprocess.run(
        [str(ROOT / "setup.sh"), "--help"],
        check=True,
        capture_output=True,
        text=True,
    )
    assert "--mlx" in help_result.stdout
    assert "--onnx" in help_result.stdout


def test_supertonic_paths_and_port_are_consistent() -> None:
    installer = installer_text()
    plist = SUPERTONIC_PLIST.read_text(encoding="utf-8")
    assert 'SUPERTONIC_PORT="${SUPERTONIC_PORT:-8766}"' in installer
    assert "assets/supertonic-3/onnx" in installer
    assert "assets/supertonic-3/voice_styles" in installer
    assert "assets/supertonic-3-mlx" in installer
    assert "assets/supertonic-3/onnx" in plist
    assert "assets/supertonic-3/voice_styles" in plist
    assert "assets/supertonic-3-mlx" in plist
    assert "127.0.0.1" in plist


def test_apple_silicon_mlx_policy_and_fallback_are_present() -> None:
    installer = installer_text()
    plist = SUPERTONIC_PLIST.read_text(encoding="utf-8")
    assert "SUPERTONIC_INSTALL_MLX=true" in installer
    assert "SUPERTONIC_BACKEND=auto" in installer
    assert "SUPERTONIC_BACKEND=mlx" in installer
    assert "SUPERTONIC_BACKEND=cpu" in installer
    assert 'py[mlx]' in installer
    assert "mlx-community/supertonic-3" in installer
    assert "SUPERTONIC_MLX_FALLBACK_TO_ONNX" in installer
    assert "SUPERTONIC_MLX_FALLBACK_TO_ONNX" in plist
    assert "<string>auto</string>" in plist


def test_installer_uses_real_api_probes_and_reports_backend() -> None:
    installer = installer_text()
    assert "/v1/audio/transcriptions" in installer
    assert "/v1/audio/speech" in installer
    assert '"backend"' in installer or 'payload.get("backend")' in installer
    assert "Setup verified successfully" in installer
    assert "Setup Complete" not in installer


def test_legacy_chatterbox_job_is_not_managed() -> None:
    installer = installer_text()
    assert 'load_launchd_service com.opencode.tts-server' not in installer
    assert 'launchctl_load_or_kick "comnopencode.tts-server"' not in installer


def test_parakeet_template_uses_local_managed_paths() -> None:
    plist = PARAKEET_PLIST.read_text(encoding="utf-8")
    assert ".config/opencode/parakeet-stt/.venv/bin/python" in plist
    assert "PARAKEET_PORT" in plist
    assert "5093" in plist
