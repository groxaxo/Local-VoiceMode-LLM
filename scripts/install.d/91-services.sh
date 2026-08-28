# shellcheck shell=bash
load_launchd_service() {
  local label="$1" plist="$2" errors
  [[ -f "$plist" ]] || die "Missing launchd plist: $plist"
  errors="$(mktemp "${TMPDIR:-/tmp}/lvml-launchctl.XXXXXX")"
  launchd_stop "$label" "$plist"
  if ! launchctl bootstrap "gui/${UID_NUM}" "$plist" 2>"$errors"; then
    err "launchctl bootstrap failed for $label:"
    cat "$errors" >&2; rm -f "$errors"; return 1
  fi
  rm -f "$errors"
  launchctl kickstart -k "gui/${UID_NUM}/${label}"
  launchd_loaded "$label" || die "$label was not loaded by launchd"
  ok "launchd started: $label"
}

if [[ "$PLATFORM" == macos ]]; then
  info "── Starting macOS services ──"
  if [[ "$SKIP_PARAKEET" == false ]]; then
    if [[ "$PARAKEET_EXTERNAL" == true ]]; then info "Existing Parakeet-compatible service left untouched"
    else load_launchd_service com.opencode.parakeet-stt "$LAUNCHD_DIR/com.opencode.parakeet-stt.plist"; fi
  fi
  [[ "$SKIP_SUPERTONIC" == true ]] || load_launchd_service com.opencode.supertonic "$LAUNCHD_DIR/com.opencode.supertonic.plist"
elif [[ "$PLATFORM" == linux ]]; then
  info "── Installing Linux systemd user services ──"
  require_cmd systemctl
  systemd_dir="$HOME/.config/systemd/user"; mkdir -p "$systemd_dir"
  if [[ "$SKIP_PARAKEET" == false ]]; then
    cat > "$systemd_dir/opencode-parakeet-stt.service" <<SERVICE
[Unit]
Description=Parakeet STT on ${PARAKEET_PORT}
After=network.target
[Service]
ExecStart=${PARAKEET_VENV}/bin/python ${PARAKEET_DIR}/server.py
WorkingDirectory=${PARAKEET_DIR}
Restart=always
RestartSec=3
Environment=HOME=${HOME}
Environment=PARAKEET_PORT=${PARAKEET_PORT}
Environment=PARAKEET_USE_GPU=${USE_GPU}
StandardOutput=append:${CONFIG_DIR}/parakeet-stt.log
StandardError=append:${CONFIG_DIR}/parakeet-stt.log
[Install]
WantedBy=default.target
SERVICE
  fi
  if [[ "$SKIP_SUPERTONIC" == false ]]; then
    cat > "$systemd_dir/opencode-supertonic.service" <<SERVICE
[Unit]
Description=Supertonic TTS on ${SUPERTONIC_PORT}
After=network.target
[Service]
ExecStart=${SUPERTONIC_VENV}/bin/python -m uvicorn api.src.main:app --host 127.0.0.1 --port ${SUPERTONIC_PORT} --app-dir ${SUPERTONIC_DIR}/py
WorkingDirectory=${SUPERTONIC_DIR}/py
Restart=always
RestartSec=3
Environment=HOME=${HOME}
Environment=SUPERTONIC_MODEL_DIR=${SUPERTONIC_DIR}/assets/supertonic-3
Environment=ONNX_DIR=${SUPERTONIC_DIR}/assets/supertonic-3/onnx
Environment=VOICE_STYLES_DIR=${SUPERTONIC_DIR}/assets/supertonic-3/voice_styles
Environment=SUPERTONIC_MLX_MODEL_DIR=${SUPERTONIC_MLX_DIR}
Environment=SUPERTONIC_MLX_AUTO_DOWNLOAD=false
Environment=SUPERTONIC_MLX_FALLBACK_TO_ONNX=${SUPERTONIC_MLX_FALLBACK}
Environment=USE_GPU=${USE_GPU}
Environment=SUPERTONIC_ORT_BACKEND=${SUPERTONIC_BACKEND}
StandardOutput=append:${CONFIG_DIR}/supertonic.log
StandardError=append:${CONFIG_DIR}/supertonic.log
[Install]
WantedBy=default.target
SERVICE
  fi
  systemctl --user daemon-reload
  [[ "$SKIP_PARAKEET" == true ]] || systemctl --user enable --now opencode-parakeet-stt.service
  [[ "$SKIP_SUPERTONIC" == true ]] || systemctl --user enable --now opencode-supertonic.service
fi
