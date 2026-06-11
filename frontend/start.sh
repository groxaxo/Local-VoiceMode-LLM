#!/bin/bash
# start.sh — Launch the Voice Service Dashboard on :7860
set -e

VENV="$HOME/.config/opencode/tts-venv"
if [ -x "$VENV/bin/python" ]; then
    PYTHON="$VENV/bin/python"
    PIP="$VENV/bin/pip"
else
    PYTHON="python3"
    PIP="pip3"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Install dependencies into the venv if missing
"$PYTHON" -c "import fastapi, uvicorn, httpx, multipart" 2>/dev/null || {
    echo "[start] Installing frontend dependencies…"
    "$PIP" install -q fastapi uvicorn httpx python-multipart
}

PORT="${PORT:-7862}"
echo "[start] Voice Service Dashboard → http://localhost:${PORT}"
cd "$SCRIPT_DIR"
exec "$PYTHON" -m uvicorn server:app --host 0.0.0.0 --port "${PORT}" --reload
