"""Regression checks for native installer false-positive readiness."""
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

ROOT = Path(__file__).resolve().parents[1]


def shell(tmp_path, command, options=(), **environment):
    modules = ROOT / "scripts/install.d"
    script = "\n".join(
        f"source {shlex.quote(str(modules / name))}"
        for name in ("00-config.sh", "10-common.sh", "20-probes.sh")
    )
    return subprocess.run(
        ["bash", "-c", script + "\n" + command, "test", "--no-integrations", *options],
        env=dict(os.environ, HOME=str(tmp_path), VOICE_CONFIG_DIR=str(tmp_path / "config"),
                 **environment),
        capture_output=True, text=True, timeout=20,
    )


@pytest.mark.parametrize("status,payload,success", [
    (503, {"text": "model unavailable"}, False),
    (200, {"text": None}, False),
    (200, {"text": 123}, False),
    (200, {"message": "text"}, False),
    (200, ["text"], False),
    (200, {"text": ""}, True),
    (200, {"text": "working"}, True),
])
def test_health_cannot_mask_broken_transcription(tmp_path, status, payload, success):
    calls = []
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            calls.append(self.path)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"ready":true,"status":"ok"}')
        def do_POST(self):
            calls.append(self.path)
            body = self.rfile.read(int(self.headers["Content-Length"]))
            assert b"RIFF" in body and b"probe.wav" in body
            self.send_response(status)
            self.end_headers()
            self.wfile.write(json.dumps(payload).encode())
        def log_message(self, *args):
            pass
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        result = shell(tmp_path, "stt_probe_once", PARAKEET_PORT=str(server.server_port))
        assert (result.returncode == 0) is success, result.stderr
        assert calls == ["/v1/audio/transcriptions"]
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def test_check_install_refuses_occupied_port_before_installing(tmp_path):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        sock.listen()
        result = shell(tmp_path, "preflight_check_ports",
                       options=("--check-install", "--skip-supertonic"),
                       PARAKEET_PORT=str(sock.getsockname()[1]))
    assert result.returncode != 0
    assert "is unavailable" in result.stderr
    assert not (tmp_path / "config/tts-venv").exists()


def test_check_install_rejects_duplicate_selected_ports(tmp_path):
    result = shell(tmp_path, "preflight_check_ports", options=("--check-install",),
                   PARAKEET_PORT="25093", SUPERTONIC_PORT="25093")
    assert result.returncode != 0
    assert "duplicate check-install port" in result.stderr


def test_old_python_is_not_selected_for_venvs(tmp_path):
    result = shell(tmp_path, """
python3.12() { return 1; }
python3.11() { return 0; }
python_for_venv
""")
    assert result.returncode == 0
    assert result.stdout.strip() == "python3.11"


def test_python_selection_fails_when_all_candidates_are_unsupported(tmp_path):
    result = shell(tmp_path, """
python3.12() { return 1; }
python3.11() { return 1; }
python3.13() { return 1; }
python3.14() { return 1; }
python3() { return 1; }
python_for_venv
""")
    assert result.returncode != 0


def test_venv_only_does_not_require_service_ports(tmp_path):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        sock.listen()
        result = shell(tmp_path, "preflight_check_ports",
                       options=("--check-install", "--venv-only"),
                       PARAKEET_PORT=str(sock.getsockname()[1]))
    assert result.returncode == 0
