# syntax=docker/dockerfile:1.7

ARG PYTHON_VERSION=3.12
ARG APP_UID=10001
ARG APP_GID=10001

FROM python:${PYTHON_VERSION}-slim AS common

ARG APP_UID
ARG APP_GID
ARG APP_VERSION=dev
ARG VCS_REF=unknown

LABEL org.opencontainers.image.title="Local VoiceMode LLM" \
      org.opencontainers.image.description="Local-first voice orchestration for AI agents" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="https://github.com/groxaxo/Local-VoiceMode-LLM"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    HOME=/home/voicemode \
    XDG_CACHE_HOME=/home/voicemode/.cache \
    TORCH_HOME=/home/voicemode/.cache/torch \
    HF_HOME=/home/voicemode/.cache/huggingface \
    PYTHONPATH=/app \
    TTS_SH=/app/service/tts.sh \
    TTS_BACKEND_SH=/app/service/tts_backends.sh \
    TTS_SENTENCE_TAGGER_PY=/app/service/xai_sentence_tagger.py

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl tini \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid "${APP_GID}" voicemode \
    && useradd --uid "${APP_UID}" --gid voicemode --home-dir /home/voicemode --create-home voicemode \
    && mkdir -p /home/voicemode/.config/opencode /home/voicemode/.cache /app \
    && chown -R voicemode:voicemode /home/voicemode /app

WORKDIR /app
COPY --chown=voicemode:voicemode README.md ./
COPY --chown=voicemode:voicemode frontend ./frontend
COPY --chown=voicemode:voicemode service ./service
COPY --chown=voicemode:voicemode integrations ./integrations
COPY --chown=voicemode:voicemode skill ./skill

RUN chmod +x service/*.sh service/*.py \
    integrations/ai-sentence-tagger/*.sh \
    integrations/ai-sentence-tagger/*.py \
    integrations/supertonic2/*.sh \
    integrations/ollama/install.sh \
    integrations/ollama/ollama-voice

USER voicemode
ENTRYPOINT ["tini", "--"]

FROM common AS dashboard

USER root
RUN python -m pip install -r /app/frontend/requirements.txt
USER voicemode

ENV PORT=7862 \
    SUPERTONIC_URL=http://host.docker.internal:8766 \
    PARAKEET_URL=http://host.docker.internal:5093

EXPOSE 7862

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:7862/', timeout=3)"

CMD ["python", "-m", "uvicorn", "server:app", "--app-dir", "/app/frontend", "--host", "0.0.0.0", "--port", "7862"]

FROM common AS audio

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       alsa-utils \
       ffmpeg \
       libportaudio2 \
       libsndfile1 \
       pulseaudio-utils \
    && rm -rf /var/lib/apt/lists/* \
    && python -m pip install --index-url https://download.pytorch.org/whl/cpu torch torchaudio \
    && python -m pip install numpy onnxruntime silero-vad sounddevice
USER voicemode

CMD ["sleep", "infinity"]
