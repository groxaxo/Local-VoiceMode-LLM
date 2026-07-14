# shellcheck shell=bash
verify_supertonic_model() {
  local model="$SUPERTONIC_DIR/assets/supertonic-3" f
  [[ -s "$model/onnx/tts.json" && -s "$model/onnx/unicode_indexer.json" ]] || return 1
  for f in duration_predictor.onnx text_encoder.onnx vector_estimator.onnx vocoder.onnx; do
    [[ -f "$model/onnx/$f" && "$(wc -c < "$model/onnx/$f")" -gt 1000000 ]] || return 1
  done
  compgen -G "$model/voice_styles/*.json" >/dev/null
}
download_supertonic_model() {
  local model="$SUPERTONIC_DIR/assets/supertonic-3" media raw f voice
  verify_supertonic_model && { ok "Supertonic model assets already verified"; return 0; }
  rm -rf "$model"; mkdir -p "$model/onnx" "$model/voice_styles"
  media=https://media.githubusercontent.com/media/groxaxo/supertonic-3-v2/main
  raw=https://raw.githubusercontent.com/groxaxo/supertonic-3-v2/main
  for f in duration_predictor.onnx text_encoder.onnx vector_estimator.onnx vocoder.onnx; do retry 3 2 curl -fL --retry 2 -o "$model/onnx/$f" "$media/onnx/$f" || break; done
  for f in tts.json unicode_indexer.json; do retry 3 2 curl -fL --retry 2 -o "$model/onnx/$f" "$raw/onnx/$f" || break; done
  for voice in F1 F2 F3 F4 F5 M1 M2 M3 M4 M5; do retry 3 2 curl -fL --retry 2 -o "$model/voice_styles/$voice.json" "$raw/voice_styles/$voice.json" || break; done
  if ! verify_supertonic_model; then
    warn "FP16 download incomplete; trying the repository downloader"
    rm -rf "$model"; mkdir -p "$model"
    "$SUPERTONIC_VENV/bin/python" "$SUPERTONIC_DIR/scripts/download_supertonic3.py" --repo-id Supertone/supertonic-3 --dest "$model"
  fi
  verify_supertonic_model || die "Supertonic model download is incomplete"
  ok "Supertonic model assets verified"
}
install_supertonic() {
  [[ "$SKIP_SUPERTONIC" == true ]] && return 0
  info "── Installing Supertonic TTS ──"
  if [[ -d "$SUPERTONIC_DIR/.git" ]]; then retry 3 2 git -C "$SUPERTONIC_DIR" pull --ff-only
  elif [[ -e "$SUPERTONIC_DIR" ]]; then
    [[ "$FORCE" == true ]] || die "$SUPERTONIC_DIR exists but is not a git checkout; use --force"
    rm -rf "$SUPERTONIC_DIR"; retry 3 2 git clone https://github.com/groxaxo/supertonic-express-3 "$SUPERTONIC_DIR"
  else retry 3 2 git clone https://github.com/groxaxo/supertonic-express-3 "$SUPERTONIC_DIR"; fi
  create_venv "$SUPERTONIC_VENV" Supertonic
  pip_install "$SUPERTONIC_VENV/bin/python" --upgrade pip setuptools wheel
  [[ -f "$SUPERTONIC_DIR/py/requirements.txt" ]] || die "Supertonic requirements are missing"
  pip_install "$SUPERTONIC_VENV/bin/python" -r "$SUPERTONIC_DIR/py/requirements.txt"
  pip_install "$SUPERTONIC_VENV/bin/python" huggingface-hub transformers
  [[ "$ACCEL" == cuda ]] && pip_install "$SUPERTONIC_VENV/bin/python" onnxruntime-gpu
  validate_imports "$SUPERTONIC_VENV/bin/python" Supertonic fastapi uvicorn onnxruntime huggingface_hub
  download_supertonic_model

  [[ "$PLATFORM" == macos ]] || return 0
  local plist="$LAUNCHD_DIR/com.opencode.supertonic.plist"
  if [[ -f "$plist" ]] && ! grep -Fq "$SUPERTONIC_DIR" "$plist" && [[ "$FORCE" == false ]]; then die "Conflicting Supertonic plist exists; use --force"; fi
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.opencode.supertonic</string>
<key>ProgramArguments</key><array><string>${SUPERTONIC_VENV}/bin/python</string><string>-m</string><string>uvicorn</string><string>api.src.main:app</string><string>--host</string><string>127.0.0.1</string><string>--port</string><string>${SUPERTONIC_PORT}</string><string>--app-dir</string><string>${SUPERTONIC_DIR}/py</string></array>
<key>EnvironmentVariables</key><dict>
<key>HOME</key><string>${HOME}</string><key>PATH</key><string>${SUPERTONIC_VENV}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
<key>SUPERTONIC_MODEL_DIR</key><string>${SUPERTONIC_DIR}/assets/supertonic-3</string><key>ONNX_DIR</key><string>${SUPERTONIC_DIR}/assets/supertonic-3/onnx</string><key>VOICE_STYLES_DIR</key><string>${SUPERTONIC_DIR}/assets/supertonic-3/voice_styles</string>
<key>USE_GPU</key><string>${USE_GPU}</string><key>SUPERTONIC_ORT_BACKEND</key><string>${ORT_BACKEND}</string><key>LOG_LEVEL</key><string>INFO</string></dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>WorkingDirectory</key><string>${SUPERTONIC_DIR}/py</string>
<key>StandardOutPath</key><string>${CONFIG_DIR}/supertonic.log</string><key>StandardErrorPath</key><string>${CONFIG_DIR}/supertonic.log</string>
</dict></plist>
PLIST
  plutil -lint "$plist" >/dev/null
  ok "Supertonic launchd definition installed with correct model paths"
}
