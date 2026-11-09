"""Run installer policy with simulated NVIDIA availability; never install anything."""
import os
from pathlib import Path
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("args,available,expected", [
    ([], True, ["cpu", "false", "cpu"]),
    ([], False, ["cpu", "false", "cpu"]),
    (["--cpu"], True, ["cpu", "false", "cpu"]),
    (["--gpu"], True, ["cuda", "true", "cuda"]),
    (["--gpu"], False, ["cpu", "false", "cpu"]),
    (["--gpu", "--onnx"], True, ["cuda", "true", "cpu"]),
])
def test_cpu_is_default_and_gpu_requires_flag(tmp_path, args, available, expected):
    fake = tmp_path / "nvidia-smi"
    fake.write_text(f'#!/bin/sh\nprintf probed >> "$HOME/probed"\nexit {0 if available else 1}\n')
    fake.chmod(0o755)
    uname = tmp_path / "uname"
    uname.write_text('#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo x86_64;; esac\n')
    uname.chmod(0o755)
    script = '''
set -Eeuo pipefail
source "$MODULES/00-config.sh"
source "$MODULES/10-common.sh"
printf 'policy=%s,%s,%s\\n' "$ACCEL" "$USE_GPU" "$SUPERTONIC_BACKEND"
'''
    result = subprocess.run(["bash", "-c", script, "test", *args],
        env={"HOME": str(tmp_path), "PATH": str(tmp_path) + os.pathsep + os.environ["PATH"],
             "MODULES": str(ROOT / "scripts/install.d")},
        stdin=subprocess.DEVNULL, capture_output=True, text=True, check=True)
    assert "policy=" + ",".join(expected) in result.stdout
    assert (tmp_path / "probed").exists() == ("--gpu" in args)


def test_invalid_image_backend_fails_before_build_mutations():
    result = subprocess.run(["bash", str(ROOT / "containers/install-speech.sh"),
                             "supertonic", "auto"], capture_output=True, text=True)
    assert result.returncode == 2
    assert "Unsupported backend" in result.stderr
