# shellcheck shell=bash
PARAKEET_EXTERNAL=false
install_parakeet() {
  [[ "$SKIP_PARAKEET" == true ]] && return 0
  info "── Installing Parakeet STT ──"
  if [[ -d "$PARAKEET_DIR/.git" ]]; then retry 3 2 git -C "$PARAKEET_DIR" pull --ff-only
  elif [[ -e "$PARAKEET_DIR" ]]; then
    [[ "$FORCE" == true ]] || die "$PARAKEET_DIR exists but is not a git checkout; use --force"
    rm -rf "$PARAKEET_DIR"; retry 3 2 git clone https://github.com/groxaxo/parakeet-tdt-0.6b-v3-fastapi-openai "$PARAKEET_DIR"
  else retry 3 2 git clone https://github.com/groxaxo/parakeet-tdt-0.6b-v3-fastapi-openai "$PARAKEET_DIR"; fi
  create_venv "$PARAKEET_VENV" Parakeet
  pip_install "$PARAKEET_VENV/bin/python" --upgrade pip setuptools wheel
  [[ -f "$PARAKEET_DIR/requirements.txt" ]] || die "Parakeet requirements.txt is missing"
  if [[ "$ACCEL" == cuda ]]; then pip_install "$PARAKEET_VENV/bin/python" -r "$PARAKEET_DIR/requirements.txt"
  else
    sed -E 's/^onnxruntime-gpu([^[:space:]]*)/onnxruntime/' "$PARAKEET_DIR/requirements.txt" > "$PARAKEET_DIR/requirements-cpu.txt"
    pip_install "$PARAKEET_VENV/bin/python" -r "$PARAKEET_DIR/requirements-cpu.txt"
  fi
  pip_install "$PARAKEET_VENV/bin/python" 'uvicorn[standard]' fastapi python-multipart silero-vad
  if "$PARAKEET_VENV/bin/python" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,13) else 1)'; then pip_install "$PARAKEET_VENV/bin/python" audioop-lts; fi
  validate_imports "$PARAKEET_VENV/bin/python" Parakeet fastapi uvicorn multipart onnxruntime

  [[ "$PLATFORM" == macos ]] || return 0
  local plist="$LAUNCHD_DIR/com.opencode.parakeet-stt.plist"
  if [[ -f "$plist" ]] && ! grep -Fq "$PARAKEET_DIR" "$plist" && [[ "$FORCE" == false ]]; then
    PARAKEET_EXTERNAL=true
    warn "Preserving existing Parakeet-compatible plist; it must pass the transcription probe"
    return 0
  fi
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.opencode.parakeet-stt</string>
<key>ProgramArguments</key><array><string>${PARAKEET_VENV}/bin/python</string><string>${PARAKEET_DIR}/server.py</string></array>
<key>EnvironmentVariables</key><dict>
<key>HOME</key><string>${HOME}</string><key>PATH</key><string>${PARAKEET_VENV}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
<key>PARAKEET_PORT</key><string>${PARAKEET_PORT}</string><key>PARAKEET_USE_GPU</key><string>${USE_GPU}</string>
<key>PARAKEET_DEFAULT_MODEL</key><string>parakeet-tdt-0.6b-v3</string></dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>WorkingDirectory</key><string>${PARAKEET_DIR}</string>
<key>StandardOutPath</key><string>${CONFIG_DIR}/parakeet-stt.log</string><key>StandardErrorPath</key><string>${CONFIG_DIR}/parakeet-stt.log</string>
</dict></plist>
PLIST
  plutil -lint "$plist" >/dev/null
  ok "Parakeet launchd definition installed"
}
