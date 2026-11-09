"""Validate the rendered Compose contracts when the Compose CLI is available."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def compose():
    binary = os.environ.get("LVML_COMPOSE_BIN")
    if binary:
        return [binary]
    if shutil.which("docker"):
        result = subprocess.run(["docker", "compose", "version"], capture_output=True)
        if result.returncode == 0:
            return ["docker", "compose"]
    pytest.skip("Docker Compose CLI is unavailable; set LVML_COMPOSE_BIN for a standalone CLI")


@pytest.mark.parametrize("gpu", [False, True])
def test_inference_configuration_requires_explicit_gpu_opt_in(compose, gpu):
    command = compose + ["-f", "docker-compose.yml", "-f", "docker-compose.cpu.yml"]
    if gpu:
        command += ["-f", "docker-compose.gpu.yml"]
    result = subprocess.run(command + ["config", "--format", "json"],
        cwd=ROOT, capture_output=True, text=True, check=True,
        env={**os.environ, "BIND_ADDRESS": "127.0.0.1"})
    services = json.loads(result.stdout)["services"]
    for name in ["parakeet", "supertonic"]:
        service = services[name]
        assert service["build"]["dockerfile"] == ("Dockerfile.gpu" if gpu else "Dockerfile.cpu")
        assert service["build"]["target"] == name
        assert service["ports"][0]["host_ip"] == "127.0.0.1"
        devices = service.get("deploy", {}).get("resources", {}).get("reservations", {}).get("devices", [])
        assert devices == ([{"driver": "nvidia", "count": 1, "capabilities": ["gpu"]}] if gpu else [])
    assert services["supertonic"]["environment"]["SUPERTONIC_ORT_BACKEND"] == ("cuda" if gpu else "cpu")
    assert services["parakeet"]["environment"]["PARAKEET_USE_GPU"] == ("true" if gpu else "false")
    assert services["dashboard"]["environment"]["SUPERTONIC_URL"] == "http://supertonic:8766"
