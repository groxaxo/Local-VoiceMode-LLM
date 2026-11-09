#!/usr/bin/env python3
"""Optional local Apple Silicon STT: Parakeet v3 or Bark Pro, MLX 8-bit."""
from contextlib import asynccontextmanager
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
import asyncio
import io
import json
import os
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import PlainTextResponse


@dataclass(frozen=True)
class Config:
    model_path: Path
    backend: str
    max_upload_bytes: int = 32 * 1024 * 1024
    max_audio_seconds: int = 600

    @classmethod
    def from_env(cls):
        backend = os.environ["VOICE_STT_BACKEND"]
        if backend not in ("parakeet-mlx", "bark-mlx"):
            raise ValueError("Select parakeet-mlx or bark-mlx")
        return cls(Path(os.environ["VOICE_STT_MODEL"]).expanduser(), backend)

    @property
    def model_id(self):
        return "bark-pro-mlx8" if self.backend == "bark-mlx" else "parakeet-mlx8"


def checkpoint_files(path):
    """Reject missing/deleted/sharded weights before claiming readiness."""
    index = path / "model.safetensors.index.json"
    if index.is_file():
        names = set(json.loads(index.read_text())["weight_map"].values())
        files = [path / name for name in names]
        if any(file.resolve().parent != path.resolve() for file in files):
            raise ValueError("Weight index must name files in the checkpoint directory")
    else:
        files = list(path.glob("*.safetensors"))
    if not (path/"config.json").is_file() or not files or any(not p.is_file() or p.stat().st_size == 0 for p in files):
        raise ValueError("Local MLX checkpoint is incomplete or its weights are missing")
    return files


class Engine:
    def __init__(self, config):
        os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1")
        import mlx.core as mx
        from mlx_audio.stt import load
        checkpoint_files(config.model_path)
        mx.set_default_device(mx.gpu)
        self.config = config
        self.model = load(str(config.model_path), strict=True, model_type="parakeet")
        mx.eval(self.model.parameters())
        mx.synchronize()
        self.memory = {"peak_mlx_active_bytes": mx.get_peak_memory()}

    def transcribe(self, payload):
        import mlx.core as mx
        import numpy as np
        import soundfile as sf
        import soxr
        try:
            audio, rate = sf.read(io.BytesIO(payload), dtype="float32", always_2d=True)
        except (sf.LibsndfileError, RuntimeError) as exc:
            raise HTTPException(415, "Audio format could not be decoded") from exc
        audio = audio.mean(axis=1)
        duration = len(audio) / rate
        if not len(audio) or not np.isfinite(audio).all():
            raise HTTPException(400, "Audio must be nonempty and finite")
        if duration > self.config.max_audio_seconds:
            raise HTTPException(413, "Audio exceeds the 600-second limit")
        if rate != 16000:
            audio = soxr.resample(audio, rate, 16000)
        data = mx.array(np.concatenate([np.zeros(4000, np.float32), audio]))
        result = self.model.generate(data, dtype=mx.bfloat16, chunk_duration=30.0,
                                     overlap_duration=2.0, verbose=False)
        mx.synchronize()
        segments, words = [], []
        def bounded(value):
            return max(0.0, min(duration, float(value) - 0.25))
        for sentence in result.sentences:
            sentence_words = []
            for token in sentence.tokens:
                text = token.text
                if not text or text.startswith("<|"):
                    continue
                start, end = bounded(token.start), bounded(token.end)
                if text[:1].isspace() or not sentence_words:
                    if text.strip():
                        sentence_words.append(dict(word=text.strip(), start=start, end=max(start, end)))
                else:
                    sentence_words[-1]["word"] += text
                    sentence_words[-1]["end"] = max(sentence_words[-1]["end"], end)
            words.extend(sentence_words)
            start = bounded(sentence.start)
            segments.append(dict(id=len(segments), start=start, end=max(start, bounded(sentence.end)),
                                 text=sentence.text.strip()))
        self.memory = dict(peak_mlx_active_bytes=mx.get_peak_memory(),
                           active_mlx_bytes=mx.get_active_memory(),
                           cache_mlx_bytes=mx.get_cache_memory())
        return dict(text=result.text.strip(), duration=duration, segments=segments, words=words,
                    model=self.config.model_id, backend=self.config.backend, **self.memory)


def create_app(engine_factory=None, config=None):
    config = config or Config.from_env()

    @asynccontextmanager
    async def lifespan(app):
        executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx-stt")
        app.state.ready = False
        app.state.lock = asyncio.Lock()
        try:
            app.state.engine = await asyncio.get_running_loop().run_in_executor(
                executor, engine_factory or (lambda: Engine(config)))
            app.state.ready = True
            app.state.executor = executor
            yield
        finally:
            app.state.ready = False
            executor.shutdown(wait=True)

    app = FastAPI(title="Optional local MLX STT", lifespan=lifespan)

    @app.get("/health")
    @app.get("/healthz")
    def health():
        if not getattr(app.state, "ready", False):
            raise HTTPException(503, "Model is not ready")
        try:
            checkpoint_files(config.model_path)
        except (ValueError, OSError, KeyError) as exc:
            raise HTTPException(503, "Model files are missing or incomplete") from exc
        return dict(ready=True, status="ok", backend=config.backend, model=config.model_id,
                    **app.state.engine.memory)

    @app.get("/v1/models")
    def models():
        return {"object":"list", "data":[{"id":config.model_id, "object":"model", "owned_by":"local"}]}

    @app.post("/v1/audio/transcriptions")
    async def transcriptions(file: UploadFile = File(...), model: str = Form(""),
                             response_format: str = Form("json"), language: str | None = Form(None)):
        try:
            if model not in ("", config.model_id, "parakeet-tdt-0.6b-v3", str(config.model_path)):
                raise HTTPException(400, "Requested model is not selected by this server")
            if response_format not in ("json", "text", "verbose_json"):
                raise HTTPException(400, "Supported formats: json, text, verbose_json")
            if app.state.lock.locked():
                raise HTTPException(429, "Transcription is busy; retry shortly")
            async with app.state.lock:
                payload = await file.read(config.max_upload_bytes + 1)
                if len(payload) > config.max_upload_bytes:
                    raise HTTPException(413, "Upload exceeds the 32 MiB limit")
                if not payload:
                    raise HTTPException(400, "Audio upload is empty")
                result = await asyncio.get_running_loop().run_in_executor(
                    app.state.executor, app.state.engine.transcribe, payload)
            if response_format == "text":
                return PlainTextResponse(result["text"])
            return result if response_format == "verbose_json" else {"text":result["text"]}
        finally:
            await file.close()
    return app


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(create_app(), host=os.getenv("PARAKEET_HOST", "127.0.0.1"),
                port=int(os.getenv("PARAKEET_PORT", "5093")))
