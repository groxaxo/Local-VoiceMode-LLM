"""Offline regression tests for the Unix installer's Supertonic clone preflight."""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "scripts/install.d/40-supertonic.sh"
INSTALL = ROOT / "scripts/install.d/90-install.sh"
DEFAULT_URL = "https://github.com/groxaxo/supertonic-express-3"
pytestmark = pytest.mark.skipif(os.name == "nt", reason="Unix installer tests")


@pytest.fixture
def env(tmp_path: Path) -> dict[str, str]:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    git = fake_bin / "git"
    git.write_text('''#!/usr/bin/env bash
printf 'PROMPT=%s\\n' "${GIT_TERMINAL_PROMPT-unset}" >> "$GIT_CALLS"
printf '<%s>\\n' "$@" >> "$GIT_CALLS"
printf '%s\\n' "${FAKE_GIT_STDERR-}" >&2
exit "${FAKE_GIT_EXIT:-0}"
''')
    git.chmod(0o755)
    result = dict(os.environ)
    result.pop("SUPERTONIC_REPO_URL", None)
    result.update(
        PATH=f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
        HOME=str(tmp_path),
        GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
        GIT_CALLS=str(tmp_path / "git-calls"),
        MUTATIONS=str(tmp_path / "mutations"),
        FAKE_GIT_EXIT="0", FAKE_GIT_STDERR="",
        SUPERTONIC_DIR=str(tmp_path / "voice config" / "supertonic-tts"),
        SUPERTONIC_VENV=str(tmp_path / "tts-venv"),
        VENV_DIR=str(tmp_path / "core-venv"),
        SKIP_SUPERTONIC="false", VENV_ONLY="false", FORCE="false",
        DOCTOR_ONLY="false", UNINSTALL="false", PLATFORM="macos",
        OS="Darwin", ARCH="arm64", ACCEL="cpu", SUPERTONIC_BACKEND="auto",
        SUPERTONIC_INSTALL_MLX="true",
    )
    return result


def run_shell(env: dict[str, str], action: str) -> subprocess.CompletedProcess[str]:
    # Stop at the first installation mutation; never install packages or services.
    script = '''set -Eeuo pipefail
info() { :; }
err() { printf '%s\\n' "$*" >&2; }
die() { err "$*"; exit 1; }
require_cmd() { :; }
show_doctor() { return 0; }
uninstall_stack() { return 0; }
retry() { shift 2; "$@"; }
create_venv() { printf 'create_venv\\n' >> "$MUTATIONS"; exit 91; }
source "$1"
'''
    return subprocess.run(
        ["bash", "-c", script + action, "test", str(MODULE), str(INSTALL)],
        env=env, capture_output=True, text=True, timeout=10,
    )


def calls(env: dict[str, str]) -> str:
    path = Path(env["GIT_CALLS"])
    return path.read_text() if path.exists() else ""


@pytest.mark.parametrize("exit_code", [2, 128])
def test_unavailable_source_stops_before_packages(env: dict[str, str], exit_code: int) -> None:
    env["FAKE_GIT_EXIT"] = str(exit_code)
    result = run_shell(env, 'source "$2"')
    assert result.returncode == 1
    assert "Cannot access the Supertonic 3 runtime repository" in result.stderr
    assert "--skip-supertonic" in result.stderr
    assert "SUPERTONIC_REPO_URL" in result.stderr
    assert not Path(env["MUTATIONS"]).exists()
    assert not Path(env["SUPERTONIC_DIR"]).exists()
    assert calls(env).count("<ls-remote>") == 1
    assert "<clone>" not in calls(env)


def test_probe_uses_default_url_without_terminal_prompt(env: dict[str, str]) -> None:
    result = run_shell(env, "preflight_supertonic_source")
    assert result.returncode == 0, result.stderr
    assert calls(env) == f"PROMPT=0\n<ls-remote>\n<--exit-code>\n<-->\n<{DEFAULT_URL}>\n<HEAD>\n"


def test_failed_probe_does_not_echo_credentials(env: dict[str, str]) -> None:
    env.update(
        SUPERTONIC_REPO_URL="https://user:secret-value@example.invalid/runtime.git",
        FAKE_GIT_EXIT="128", FAKE_GIT_STDERR="fatal: secret-value",
    )
    result = run_shell(env, "preflight_supertonic_source")
    assert result.returncode == 1
    assert "secret-value" not in result.stdout + result.stderr


@pytest.mark.parametrize("flag", ["SKIP_SUPERTONIC", "VENV_ONLY"])
def test_partial_modes_do_not_probe(env: dict[str, str], flag: str) -> None:
    env[flag] = "true"
    env["FAKE_GIT_EXIT"] = "128"
    result = run_shell(env, 'source "$2"')
    assert result.returncode == 91, result.stderr  # reached normal venv creation
    assert not calls(env)


@pytest.mark.parametrize("flag", ["DOCTOR_ONLY", "UNINSTALL"])
def test_maintenance_modes_do_not_probe(env: dict[str, str], flag: str) -> None:
    env[flag] = "true"
    env["FAKE_GIT_EXIT"] = "128"
    result = run_shell(env, 'source "$2"')
    assert result.returncode == 0, result.stderr
    assert not calls(env)
    assert not Path(env["MUTATIONS"]).exists()


def test_force_preserves_conflicting_files_when_access_fails(env: dict[str, str]) -> None:
    target = Path(env["SUPERTONIC_DIR"])
    target.mkdir(parents=True)
    sentinel = target / "keep-me"
    sentinel.write_text("existing data")
    env.update(FORCE="true", FAKE_GIT_EXIT="128")
    result = run_shell(env, 'source "$2"')
    assert result.returncode == 1
    assert sentinel.read_text() == "existing data"
    assert not Path(env["MUTATIONS"]).exists()


def test_conflict_without_force_is_rejected_without_network(env: dict[str, str]) -> None:
    Path(env["SUPERTONIC_DIR"]).mkdir(parents=True)
    result = run_shell(env, "preflight_supertonic_source")
    assert result.returncode == 1
    assert "not a git checkout" in result.stderr
    assert not calls(env)


def test_existing_checkout_keeps_normal_pull_path(env: dict[str, str]) -> None:
    (Path(env["SUPERTONIC_DIR"]) / ".git").mkdir(parents=True)
    env["SUPERTONIC_REPO_URL"] = "https://example.invalid/not-a-migration.git"
    result = run_shell(env, "preflight_supertonic_source\ninstall_supertonic")
    assert result.returncode == 91, result.stderr
    assert "<ls-remote>" not in calls(env)
    assert "<clone>" not in calls(env)
    assert "<pull>\n<--ff-only>" in calls(env)
    assert "not-a-migration" not in calls(env)


@pytest.mark.parametrize("force", [False, True])
def test_both_clone_paths_use_checked_override(env: dict[str, str], force: bool) -> None:
    # Spaces exercise shell argument quoting, without any real network access.
    url = "/trusted local/runtime source"
    env["SUPERTONIC_REPO_URL"] = url
    if force:
        Path(env["SUPERTONIC_DIR"]).mkdir(parents=True)
        env["FORCE"] = "true"
    result = run_shell(env, "preflight_supertonic_source\ninstall_supertonic")
    assert result.returncode == 91, result.stderr
    trace = calls(env)
    assert trace.count(f"<{url}>") == 2
    assert f"<clone>\n<-->\n<{url}>\n<{env['SUPERTONIC_DIR']}>" in trace
    assert trace.count("PROMPT=0") == 2
    assert DEFAULT_URL not in trace


@pytest.mark.parametrize("has_commit", [False, True])
def test_probe_against_real_local_git(env: dict[str, str], tmp_path: Path, has_commit: bool) -> None:
    git = shutil.which("git")
    if git is None:
        pytest.skip("git is required for the local repository probe")
    repo = tmp_path / "real runtime source"
    # Replace the fake Git with the real executable; all operations remain local.
    env["PATH"] = os.environ["PATH"]
    subprocess.run([git, "init", "-q", str(repo)], env=env, check=True)
    if has_commit:
        subprocess.run([
            git, "-C", str(repo), "-c", "user.name=Source test",
            "-c", "user.email=source-test@example.invalid", "-c", "commit.gpgsign=false",
            "-c", f"core.hooksPath={os.devnull}", "commit", "--allow-empty", "-qm", "fixture",
        ], env=env, check=True)
    env["SUPERTONIC_REPO_URL"] = str(repo)
    result = run_shell(env, "preflight_supertonic_source")
    assert result.returncode == (0 if has_commit else 1), result.stderr
