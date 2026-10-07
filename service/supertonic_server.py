"""Public Supertonic 3 adapter. No private runtime source or MLX dependency.

Uses the pinned Supertone MIT SDK; model assets retain their Open RAIL-M license.
Only buffered WAV is required by Local VoiceMode. Inference is serialized.
"""
from contextlib import asynccontextmanager
import io
import os
import threading

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, ConfigDict, Field, model_validator


MODEL_REVISION = "724fb5abbf5502583fb520898d45929e62f02c0b"


class SpeechRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    model: str = "supertonic-3"
    input: str = Field(min_length=1, max_length=10000)
    voice: str = "F3"
    lang: str | None = None
    lang_code: str | None = None  # compatibility for already-installed clients
    speed: float = Field(default=1.05, ge=0.7, le=2.0)
    total_steps: int = Field(default=8, ge=1, le=100)
    response_format: str = "wav"
    stream: bool = False

    @model_validator(mode="after")
    def compatible_language(self):
        if self.lang and self.lang_code and self.lang != self.lang_code:
            raise ValueError("lang and lang_code conflict")
        self.lang = self.lang or self.lang_code or "en"
        return self


def load_engine():
    import onnxruntime as ort
    import supertonic.loader as loader
    import supertonic.config as config
    from supertonic import TTS

    backend = os.environ.get("SUPERTONIC_ORT_BACKEND", "cpu")
    providers = {"cpu": ["CPUExecutionProvider"],
                 "cuda": ["CUDAExecutionProvider", "CPUExecutionProvider"]}
    if backend not in providers:
        raise RuntimeError("Public runtime supports cpu or cuda; MLX/CoreML are unavailable")
    requested = providers[backend]
    if requested[0] not in ort.get_available_providers():
        raise RuntimeError(f"Requested {requested[0]} is unavailable; refusing silent fallback")
    # Pinned SDK loader has no provider argument; set its public-module configuration.
    loader.DEFAULT_ONNX_PROVIDERS = requested
    config.MODEL_REVISION_ENV_OVERRIDE = MODEL_REVISION
    tts = TTS(model="supertonic-3", model_dir=os.environ.get("SUPERTONIC_MODEL_DIR"),
              auto_download=True)
    for voice in (f"{prefix}{i}" for prefix in ("F", "M") for i in range(1, 6)):
        tts.get_voice_style(voice)
    return tts


def runtime_health(engine):
    sessions = {name: getattr(engine.model, name).get_providers()
                for name in ("dp_ort", "text_enc_ort", "vector_est_ort", "vocoder_ort")}
    primary = {providers[0] for providers in sessions.values() if providers}
    backend = ("cuda" if primary == {"CUDAExecutionProvider"} else
               "cpu" if primary == {"CPUExecutionProvider"} else "mixed")
    return {"status": "ok", "ready": True, "model": "supertonic-3",
            "backend": backend, "session_providers": sessions,
            "sample_rate": engine.sample_rate, "voices_loaded": len(engine.voice_style_names)}


def create_app(engine_factory=load_engine):
    lock = threading.Lock()

    @asynccontextmanager
    async def lifespan(app):
        app.state.engine = engine_factory()
        app.state.health = runtime_health(app.state.engine)
        app.state.ready = True
        try:
            yield
        finally:
            app.state.ready = False

    app = FastAPI(title="Local VoiceMode public Supertonic adapter", lifespan=lifespan)
    app.state.ready = False

    @app.get("/health")
    @app.get("/healthz")
    def health():
        if not app.state.ready:
            return JSONResponse({"status": "loading", "ready": False}, status_code=503)
        return app.state.health

    @app.post("/v1/audio/speech")
    def speech(req: SpeechRequest):
        if not app.state.ready:
            raise HTTPException(503, "Model not ready")
        if req.model not in ("supertonic", "supertonic-3"):
            raise HTTPException(400, "Only Supertonic 3 is loaded")
        if req.stream or req.response_format != "wav":
            raise HTTPException(400, "Only buffered WAV is supported")
        from supertonic.config import AVAILABLE_LANGUAGES
        if req.lang not in AVAILABLE_LANGUAGES:
            raise HTTPException(400, "Unsupported language")
        engine = app.state.engine
        if req.voice not in engine.voice_style_names:
            raise HTTPException(400, "Unknown voice")
        import numpy as np
        import soundfile as sf
        with lock:
            audio, _ = engine.synthesize(req.input, voice_style=engine.get_voice_style(req.voice),
                                         lang=req.lang, speed=req.speed, total_steps=req.total_steps)
        audio = np.asarray(audio).reshape(-1)
        if audio.size == 0 or not np.isfinite(audio).all():
            raise HTTPException(500, "Engine returned empty or non-finite audio")
        buf = io.BytesIO()
        sf.write(buf, audio, engine.sample_rate, format="WAV", subtype="PCM_16")
        return Response(buf.getvalue(), media_type="audio/wav")

    return app


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--prepare", action="store_true", required=True)
    parser.parse_args()
    import json
    print(json.dumps(runtime_health(load_engine())))
