# shellcheck shell=bash
install_mlx_stt() {
  info "Installing optional ${STT_BACKEND} (Apple GPU, MLX 8-bit)"
  mkdir -p "$PARAKEET_DIR"
  create_venv "$PARAKEET_VENV" "MLX STT"
  pip_install "$PARAKEET_VENV/bin/python" --upgrade pip
  pip_install "$PARAKEET_VENV/bin/python" \
    'mlx==0.32.4' \
    'git+https://github.com/Blaizzy/mlx-audio.git@f6d5da9626bcdc5be6eccb3e7b79648548dd1b22' \
    fastapi 'uvicorn[standard]' python-multipart soundfile soxr socksio
  cp "$REPO_DIR/service/mlx_stt_server.py" "$PARAKEET_DIR/server.py"
  VOICE_STT_MODEL="$PARAKEET_DIR/models/$STT_BACKEND"
  "$PARAKEET_VENV/bin/python" "$REPO_DIR/scripts/prepare_mlx_stt.py" \
    --backend "$STT_BACKEND" --output "$VOICE_STT_MODEL"
  # Strict GPU load before writing service definitions; no health-only success.
  VOICE_STT_MODEL="$VOICE_STT_MODEL" VOICE_STT_BACKEND="$STT_BACKEND" \
    "$PARAKEET_VENV/bin/python" -c \
    "import sys; sys.path.insert(0,sys.argv[1]); from server import Config, Engine; Engine(Config.from_env())" "$PARAKEET_DIR"

  [[ "$PLATFORM" == macos && "$CHECK_INSTALL" == false ]] || return 0
  local plist="$LAUNCHD_DIR/com.opencode.parakeet-stt.plist"
  if [[ -f "$plist" ]] && ! grep -Fq "$PARAKEET_DIR" "$plist" && [[ "$FORCE" == false ]]; then
    die "Existing STT service is preserved. Use --force to replace its managed plist or --check-install on an unused port."
  fi
  export PARAKEET_DIR PARAKEET_VENV PARAKEET_PORT VOICE_STT_MODEL STT_BACKEND CONFIG_DIR
  MLX_STT_PLIST="$plist" "$PARAKEET_VENV/bin/python" - <<'PY'
import os, plistlib
from pathlib import Path
c=os.environ
data=dict(
    Label="com.opencode.parakeet-stt",
    ProgramArguments=[c["PARAKEET_VENV"]+"/bin/python",c["PARAKEET_DIR"]+"/server.py"],
    EnvironmentVariables=dict(
        HOME=c["HOME"], PATH=c["PARAKEET_VENV"]+"/bin:/usr/bin:/bin",
        PARAKEET_HOST="127.0.0.1", PARAKEET_PORT=c["PARAKEET_PORT"],
        VOICE_STT_MODEL=c["VOICE_STT_MODEL"], VOICE_STT_BACKEND=c["STT_BACKEND"],
        HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", ORT_DISABLE_TELEMETRY="1"),
    RunAtLoad=True, KeepAlive=True, WorkingDirectory=c["PARAKEET_DIR"],
    StandardOutPath=c["CONFIG_DIR"]+"/parakeet-stt.log",
    StandardErrorPath=c["CONFIG_DIR"]+"/parakeet-stt.log")
Path(c["MLX_STT_PLIST"]).write_bytes(plistlib.dumps(data))
PY
  plutil -lint "$plist" >/dev/null
  ok "MLX STT launchd definition installed ($STT_BACKEND)"
}
