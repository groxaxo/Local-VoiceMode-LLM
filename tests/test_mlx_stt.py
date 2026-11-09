"""MLX optional server contract tests; GPU inference is checked on the Mac."""
import importlib.util
import io
import json
import os
import shlex
from pathlib import Path
import subprocess
import sys
import wave

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("mlx_stt_server", ROOT/"service/mlx_stt_server.py")
server = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = server
spec.loader.exec_module(server)


class Engine:
    memory = {"peak_mlx_active_bytes": 123}
    def transcribe(self, payload):
        assert payload.startswith(b"RIFF")
        return dict(text="Test words.", words=[dict(word="Test",start=0,end=1)], duration=1)


@pytest.fixture(params=["parakeet-mlx","bark-mlx"])
def config(tmp_path, request):
    (tmp_path/"config.json").write_text("{}")
    (tmp_path/"model.safetensors").write_bytes(b"weights fixture")
    return server.Config(tmp_path, request.param, max_upload_bytes=1000)


def wav():
    stream=io.BytesIO()
    with wave.open(stream,"wb") as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(16000)
        f.writeframes(b"\0\0"*100)
    return stream.getvalue()


def test_formats_and_legacy_alias(config):
    with TestClient(server.create_app(lambda:Engine(), config)) as client:
        assert client.get("/health").json()["backend"] == config.backend
        assert client.get("/v1/models").json()["data"][0]["id"] == config.model_id
        for fmt in ["json","text","verbose_json"]:
            response=client.post("/v1/audio/transcriptions", files={"file":("test.wav",wav())},
                                 data=dict(model="parakeet-tdt-0.6b-v3",response_format=fmt,language="es"))
            assert response.status_code == 200
            if fmt=="text": assert response.text == "Test words."
            else: assert response.json()["text"]=="Test words."
            if fmt=="verbose_json": assert response.json()["words"]
    assert client.get("/health").status_code == 503


def test_readiness_checks_files_even_after_loading(config):
    with TestClient(server.create_app(lambda:Engine(),config)) as client:
        (config.model_path/"model.safetensors").unlink()
        assert client.get("/health").status_code == 503


@pytest.mark.parametrize("fields,payload,status", [
    ({"model":"other-model"},b"x",400),
    ({"response_format":"srt"},b"x",400),
    ({},b"",400),
    ({},b"x"*1001,413),
])
def test_invalid_requests_do_not_reach_engine(config, fields, payload, status):
    with TestClient(server.create_app(lambda:Engine(),config)) as client:
        response=client.post("/v1/audio/transcriptions", files={"file":("test.wav",payload)}, data=fields)
        assert response.status_code == status


def test_startup_failure_is_not_healthy(config):
    def fail():
        raise RuntimeError("Could not load GPU model")
    with pytest.raises(RuntimeError,match="Could not load"):
        with TestClient(server.create_app(fail,config)):
            pass


def test_partial_sharded_checkpoint_fails_readiness(tmp_path):
    (tmp_path/"config.json").write_text("{}")
    (tmp_path/"model.safetensors.index.json").write_text(json.dumps(dict(weight_map={"a":"missing.safetensors"})))
    with pytest.raises(ValueError,match="incomplete"):
        server.checkpoint_files(tmp_path)


@pytest.mark.parametrize("backend", ["parakeet-mlx","bark-mlx"])
def test_selection_fails_early_on_non_mac(tmp_path,backend):
    script=f'source {shlex.quote(str(ROOT / "scripts/install.d/00-config.sh"))}; PLATFORM=linux; source {shlex.quote(str(ROOT / "scripts/install.d/10-common.sh"))}'
    result=subprocess.run(["bash","-c",script,"test","--stt-backend="+backend],
                          env=dict(os.environ,VOICE_CONFIG_DIR=str(tmp_path/"config")),capture_output=True,text=True)
    assert result.returncode != 0
    assert "native Apple Silicon" in result.stderr
    assert not (tmp_path/"config").exists()


def test_unknown_selection_fails_before_installing(tmp_path):
    result=subprocess.run([str(ROOT/"setup.sh"),"--stt-backend=typo"],
                          env=dict(os.environ,VOICE_CONFIG_DIR=str(tmp_path/"config")),capture_output=True,text=True)
    assert result.returncode != 0
    assert "Unknown STT backend" in result.stderr
    assert not (tmp_path/"config").exists()


def test_existing_checkpoint_must_match_pin(tmp_path):
    spec=importlib.util.spec_from_file_location("prepare_mlx",ROOT/"scripts/prepare_mlx_stt.py")
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    path=tmp_path/"checkpoint"
    path.mkdir()
    (path/"model.safetensors").write_bytes(b"corrupt")
    with pytest.raises(RuntimeError,match="SHA-256"):
        module.prepare("parakeet-mlx",path)
    assert (path/"model.safetensors").read_bytes()==b"corrupt"


def test_overlapping_request_is_rejected_instead_of_loading_more_models(config):
    import threading
    from concurrent.futures import ThreadPoolExecutor
    entered, release = threading.Event(), threading.Event()
    class BlockingEngine(Engine):
        def transcribe(self, payload):
            entered.set()
            if not release.wait(5):
                raise TimeoutError("Test inference did not finish")
            return super().transcribe(payload)
    with TestClient(server.create_app(lambda:BlockingEngine(),config)) as client:
        with ThreadPoolExecutor(max_workers=1) as pool:
            first=pool.submit(client.post,"/v1/audio/transcriptions",files={"file":("clip.wav",wav())})
            try:
                assert entered.wait(3)
                second=client.post("/v1/audio/transcriptions",files={"file":("clip.wav",wav())})
                assert second.status_code==429
            finally:
                release.set()
            assert first.result(timeout=5).status_code==200
