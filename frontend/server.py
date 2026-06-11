"""
Voice Service Frontend — FastAPI proxy server on :7860.

Routes:
  GET  /                      → index.html
  GET  /api/voices            → list available Supertonic voices
  GET  /api/status            → health of Supertonic + Parakeet
  POST /api/tts               → proxy to Supertonic :8766
  POST /api/stt               → proxy to Parakeet :5093
  GET  /api/config            → read frontend-config.json (VAD + GPU settings)
  POST /api/config            → write config, restart services if GPU changed
"""

import json
import os
import subprocess
import asyncio
from pathlib import Path
from typing import Optional

import httpx
from fastapi import FastAPI, HTTPException, UploadFile, File, Form
from fastapi.responses import HTMLResponse, StreamingResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# ── Paths ─────────────────────────────────────────────────────────────────────
HOME = Path.home()
VOICES_DIR = HOME / ".config/opencode/supertonic-tts/assets/voices"
CONFIG_FILE = HOME / ".config/opencode/frontend-config.json"
SYSTEMD_USER_DIR = HOME / ".config/systemd/user"
FRONTEND_DIR = Path(__file__).parent

SUPERTONIC_URL = os.getenv("SUPERTONIC_URL", "http://127.0.0.1:8766")
PARAKEET_URL = os.getenv("PARAKEET_URL", "http://127.0.0.1:5093")

DEFAULT_CONFIG = {
    "vad_threshold": 0.5,
    "vad_min_silence_ms": 500,
    "vad_pre_speech_ms": 800,
    "vad_max_duration_s": 30,
    "use_gpu_supertonic": False,
    "use_gpu_parakeet": False,
}

# ── App ───────────────────────────────────────────────────────────────────────
app = FastAPI(title="Voice Service UI")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── Config helpers ─────────────────────────────────────────────────────────────
def read_config() -> dict:
    if CONFIG_FILE.exists():
        try:
            return {**DEFAULT_CONFIG, **json.loads(CONFIG_FILE.read_text())}
        except Exception:
            pass
    return dict(DEFAULT_CONFIG)


def write_config(cfg: dict):
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(json.dumps(cfg, indent=2))


def write_systemd_override(service: str, env_key: str, value: str):
    drop_in_dir = SYSTEMD_USER_DIR / f"{service}.service.d"
    drop_in_dir.mkdir(parents=True, exist_ok=True)
    override = drop_in_dir / "gpu-override.conf"
    override.write_text(f"[Service]\nEnvironment={env_key}={value}\n")


async def restart_service(service: str) -> bool:
    try:
        proc = await asyncio.create_subprocess_exec(
            "systemctl", "--user", "daemon-reload",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        await proc.communicate()

        proc = await asyncio.create_subprocess_exec(
            "systemctl", "--user", "restart", service,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await proc.communicate()
        if proc.returncode != 0:
            print(f"[restart] {service} failed: {stderr.decode()}")
            return False
        return True
    except Exception as e:
        print(f"[restart] exception for {service}: {e}")
        return False


# ── Routes ────────────────────────────────────────────────────────────────────
@app.get("/", response_class=HTMLResponse)
async def index():
    html_file = FRONTEND_DIR / "index.html"
    if not html_file.exists():
        raise HTTPException(status_code=404, detail="index.html not found")
    return HTMLResponse(html_file.read_text())


@app.get("/api/voices")
async def get_voices():
    voices = []
    if VOICES_DIR.exists():
        for f in sorted(VOICES_DIR.iterdir()):
            if f.suffix == ".bin":
                voices.append(f.stem)
    if not voices:
        voices = ["M1", "M2", "M3", "M4", "M5", "F1", "F2", "F3", "F4", "F5"]
    return {"voices": voices}


@app.get("/api/status")
async def get_status():
    result = {"supertonic": False, "parakeet": False}
    async with httpx.AsyncClient(timeout=3.0) as client:
        try:
            r = await client.get(f"{SUPERTONIC_URL}/health")
            result["supertonic"] = r.status_code == 200
        except Exception:
            pass
        try:
            r = await client.get(f"{PARAKEET_URL}/health")
            result["parakeet"] = r.status_code < 500
        except Exception:
            # Parakeet may not have /health — try OPTIONS on the transcription endpoint
            try:
                r = await client.options(f"{PARAKEET_URL}/v1/audio/transcriptions")
                result["parakeet"] = True
            except Exception:
                pass
    return result


class TTSRequest(BaseModel):
    input: str
    voice: str = "M1"
    lang_code: Optional[str] = None
    total_steps: int = 15
    speed: float = 1.0
    response_format: str = "wav"
    stream: bool = False


@app.post("/api/tts")
async def proxy_tts(req: TTSRequest):
    payload = req.model_dump()
    payload["model"] = "supertonic"

    async def stream_audio():
        async with httpx.AsyncClient(timeout=60.0) as client:
            async with client.stream(
                "POST",
                f"{SUPERTONIC_URL}/v1/audio/speech",
                json=payload,
                headers={"Content-Type": "application/json"},
            ) as r:
                if r.status_code != 200:
                    body = await r.aread()
                    raise HTTPException(status_code=r.status_code, detail=body.decode())
                async for chunk in r.aiter_bytes(chunk_size=8192):
                    yield chunk

    content_types = {
        "wav": "audio/wav",
        "mp3": "audio/mpeg",
        "opus": "audio/opus",
        "flac": "audio/flac",
    }
    ct = content_types.get(req.response_format, "audio/wav")
    return StreamingResponse(stream_audio(), media_type=ct)


@app.post("/api/stt")
async def proxy_stt(
    file: UploadFile = File(...),
    model: str = Form(default="parakeet-tdt-0.6b-v3"),
):
    audio_bytes = await file.read()
    async with httpx.AsyncClient(timeout=60.0) as client:
        r = await client.post(
            f"{PARAKEET_URL}/v1/audio/transcriptions",
            files={"file": (file.filename or "audio.wav", audio_bytes, file.content_type or "audio/wav")},
            data={"model": model},
        )
    if r.status_code != 200:
        raise HTTPException(status_code=r.status_code, detail=r.text)
    return r.json()


@app.get("/api/config")
async def get_config():
    cfg = read_config()
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    if not CONFIG_FILE.exists():
        write_config(cfg)
    return cfg


@app.post("/api/config")
async def post_config(body: dict):
    old = read_config()
    new = {**old, **body}
    write_config(new)

    restarted = []
    errors = []

    if new.get("use_gpu_supertonic") != old.get("use_gpu_supertonic"):
        val = "true" if new["use_gpu_supertonic"] else "false"
        write_systemd_override("opencode-supertonic", "USE_GPU", val)
        ok = await restart_service("opencode-supertonic")
        if ok:
            restarted.append("opencode-supertonic")
        else:
            errors.append("opencode-supertonic restart failed")

    if new.get("use_gpu_parakeet") != old.get("use_gpu_parakeet"):
        val = "true" if new["use_gpu_parakeet"] else "false"
        write_systemd_override("opencode-parakeet-stt", "PARAKEET_USE_GPU", val)
        ok = await restart_service("opencode-parakeet-stt")
        if ok:
            restarted.append("opencode-parakeet-stt")
        else:
            errors.append("opencode-parakeet-stt restart failed")

    return {"saved": True, "restarted": restarted, "errors": errors}
