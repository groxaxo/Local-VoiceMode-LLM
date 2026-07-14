# shellcheck shell=bash
require_cmd curl
require_cmd python3
[[ "$PLATFORM" == macos ]] && require_cmd launchctl

if [[ "$DOCTOR_ONLY" == true ]]; then
  if show_doctor; then exit 0; else exit 1; fi
fi
if [[ "$UNINSTALL" == true ]]; then uninstall_stack; exit 0; fi
require_cmd git
info "Parakeet accelerator: ${ACCEL} (${OS} ${ARCH})"
info "Supertonic backend policy: ${SUPERTONIC_BACKEND}$( [[ "$SUPERTONIC_INSTALL_MLX" == true ]] && printf ' (MLX assets enabled)' )"

create_venv "$VENV_DIR" "Voice core"
pip_install "$VENV_DIR/bin/python" --upgrade pip setuptools wheel
pip_install "$VENV_DIR/bin/python" silero-vad sounddevice onnxruntime torch torchaudio numpy
validate_imports "$VENV_DIR/bin/python" "Voice core" numpy onnxruntime torch silero_vad
if [[ "$VENV_ONLY" == true ]]; then ok "Voice venv setup completed"; exit 0; fi

install_parakeet
install_supertonic

info "── Installing voice skill files ──"
mkdir -p "$SKILL_DIR"
for file in vad_recorder.py talk.sh tts.sh tts_lang.sh doctor.sh; do
  [[ -f "$REPO_DIR/service/$file" ]] && cp "$REPO_DIR/service/$file" "$SKILL_DIR/$file"
done
[[ -f "$REPO_DIR/skill/SKILL.md" ]] && cp "$REPO_DIR/skill/SKILL.md" "$SKILL_DIR/SKILL.md"
chmod +x "$SKILL_DIR"/*.sh "$SKILL_DIR"/vad_recorder.py 2>/dev/null || true
# The source still supports legacy Chatterbox on :8765. Installed Supertonic
# clients must point to this installer's selected Supertonic port instead.
sed -E -i.bak "s#SUPERTONIC_URL:=http://127\\.0\\.0\\.1:[0-9]+#SUPERTONIC_URL:=http://127.0.0.1:${SUPERTONIC_PORT}#" "$SKILL_DIR/tts.sh"
rm -f "$SKILL_DIR/tts.sh.bak"
cp "$SKILL_DIR/tts.sh" "$CONFIG_DIR/tts.sh"
cp "$REPO_DIR/service/tts_lang.sh" "$CONFIG_DIR/tts_lang.sh"
chmod +x "$CONFIG_DIR/tts.sh" "$CONFIG_DIR/tts_lang.sh"

install_integration() {
  local name="$1" target="$2" enabled="$3"
  [[ "$enabled" == true ]] || return 0
  if [[ "$target" == "$SKILL_DIR" ]]; then ok "Integration ready: $name → $target"; return 0; fi
  mkdir -p "$target"; cp -R "$SKILL_DIR/." "$target/"
  chmod +x "$target"/*.sh "$target"/vad_recorder.py 2>/dev/null || true
  ok "Integration ready: $name → $target"
}
install_integration "Claude Code" "$HOME/.claude/skills/talk" "$INTEGRATE_CLAUDECODE"
install_integration "OpenCode CLI" "$SKILL_DIR" "$INTEGRATE_OPENCODE"
install_integration "OpenClaw" "$HOME/.openclaw/skills/talk" "$INTEGRATE_OPENCLAW"
install_integration "Hermes Agent" "$HOME/.hermes/skills/talk" "$INTEGRATE_HERMES"
install_integration "Codex" "$HOME/.codex/skills/talk" "$INTEGRATE_CODEX"

if [[ "$SKIP_VOICES" == false && "$PLATFORM" == macos ]] && command -v say >/dev/null 2>&1 && command -v ffmpeg >/dev/null 2>&1; then
  if [[ ! -f "$CONFIG_DIR/ref_voice_en.wav" ]]; then
    if say -v Samantha -o /tmp/lvml-ref-en.aiff "Hello, I am your AI assistant." \
      && ffmpeg -loglevel error -y -i /tmp/lvml-ref-en.aiff -ar 22050 -ac 1 "$CONFIG_DIR/ref_voice_en.wav"; then
      ok "English reference voice created"
    else warn "Could not create optional English reference voice"; fi
    rm -f /tmp/lvml-ref-en.aiff
  fi
  if [[ ! -f "$CONFIG_DIR/ref_voice_es.wav" ]]; then
    if say -v 'Mónica' -o /tmp/lvml-ref-es.aiff "Hola, soy tu asistente de inteligencia artificial." \
      && ffmpeg -loglevel error -y -i /tmp/lvml-ref-es.aiff -ar 22050 -ac 1 "$CONFIG_DIR/ref_voice_es.wav"; then
      ok "Spanish reference voice created"
    else warn "Could not create optional Spanish reference voice"; fi
    rm -f /tmp/lvml-ref-es.aiff
  fi
fi
