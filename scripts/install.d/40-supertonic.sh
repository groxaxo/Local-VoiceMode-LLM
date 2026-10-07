# shellcheck shell=bash
SUPERTONIC_REPO_URL="${SUPERTONIC_REPO_URL:-https://github.com/supertone-oss-archive/supertonic-py.git}"
SUPERTONIC_REVISION=df0f9686dac7fbbde391b759e2ee5286a3737622

preflight_supertonic_source() {
  [[ "$SKIP_SUPERTONIC" == true || "$VENV_ONLY" == true ]] && return 0
  # Existing runtime sources are never migrated or deleted.
  if [[ -d "$SUPERTONIC_DIR/.git" ]]; then
    local remote
    remote="$(git -C "$SUPERTONIC_DIR" remote get-url origin)"
    [[ "$remote" == "$SUPERTONIC_REPO_URL" ]] || die "Existing Supertonic runtime differs; select a fresh VOICE_CONFIG_DIR."
    [[ -z "$(git -C "$SUPERTONIC_DIR" status --porcelain --untracked-files=no)" ]] || die "Existing Supertonic checkout has local changes; preserved."
    return 0
  fi
  if [[ -e "$SUPERTONIC_DIR" ]]; then
    die "$SUPERTONIC_DIR exists but is not a git checkout; select a fresh VOICE_CONFIG_DIR"
  fi
  info "Checking access to the Supertonic 3 runtime repository"
  # Use configured credentials, but disable terminal prompts and hide probe errors.
  if ! GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code -- "$SUPERTONIC_REPO_URL" HEAD >/dev/null 2>&1; then
    err "Cannot access the Supertonic 3 runtime repository."
    err "It may be private, missing, or unreachable; a GitHub login alone does not grant repository access."
    err "Check access/network connectivity, or set SUPERTONIC_REPO_URL to a trusted compatible source."
    die "See docs/supertonic-source.md. Use --skip-supertonic only for a partial install without local TTS."
  fi
}

install_supertonic() {
  [[ "$SKIP_SUPERTONIC" == true ]] && return 0
  info "Installing pinned public Supertonic runtime (ONNX)"
  if [[ -d "$SUPERTONIC_DIR/.git" ]]; then
    local remote
    remote="$(git -C "$SUPERTONIC_DIR" remote get-url origin)"
    [[ "$remote" == "$SUPERTONIC_REPO_URL" ]] || die "Existing Supertonic checkout uses another runtime; preserve it and select a fresh VOICE_CONFIG_DIR. See docs/supertonic-source.md."
  elif [[ -e "$SUPERTONIC_DIR" ]]; then
    die "Existing Supertonic directory is preserved; select a fresh VOICE_CONFIG_DIR."
  else
    retry 3 2 env GIT_TERMINAL_PROMPT=0 git clone -- "$SUPERTONIC_REPO_URL" "$SUPERTONIC_DIR"
  fi
  # Never pull moving upstream HEAD; refuse dirty checkouts before selecting the pin.
  [[ -z "$(git -C "$SUPERTONIC_DIR" status --porcelain --untracked-files=no)" ]] || die "Supertonic checkout has local changes; preserved without updating."
  git -C "$SUPERTONIC_DIR" cat-file -e "${SUPERTONIC_REVISION}^{commit}" || die "Pinned Supertonic commit is unavailable"
  git -C "$SUPERTONIC_DIR" checkout --detach "$SUPERTONIC_REVISION"
  create_venv "$SUPERTONIC_VENV" Supertonic
  pip_install "$SUPERTONIC_VENV/bin/python" --upgrade pip setuptools wheel
  pip_install "$SUPERTONIC_VENV/bin/python" "${SUPERTONIC_DIR}[serve]"
  if [[ "$SUPERTONIC_BACKEND" == cuda ]]; then
    "$SUPERTONIC_VENV/bin/python" -m pip uninstall -y onnxruntime
    pip_install "$SUPERTONIC_VENV/bin/python" onnxruntime-gpu
  fi
  validate_imports "$SUPERTONIC_VENV/bin/python" Supertonic fastapi uvicorn onnxruntime huggingface_hub
  cp "$REPO_DIR/service/supertonic_server.py" "$SUPERTONIC_DIR/local_voicemode_server.py"
  # Initialize all four sessions and all ten styles before installing a service.
  # Upstream downloads Supertone/supertonic-3 at its pinned public model revision.
  SUPERTONIC_MODEL_DIR="$SUPERTONIC_DIR/assets/supertonic-3" SUPERTONIC_ORT_BACKEND="$SUPERTONIC_BACKEND" \
    "$SUPERTONIC_VENV/bin/python" "$SUPERTONIC_DIR/local_voicemode_server.py" --prepare

  [[ "$PLATFORM" == macos && "$CHECK_INSTALL" == false ]] || return 0
  local plist="$LAUNCHD_DIR/com.opencode.supertonic.plist"
  if [[ -f "$plist" ]] && ! grep -Fq "$SUPERTONIC_DIR" "$plist" && [[ "$FORCE" == false ]]; then die "Conflicting Supertonic plist exists; use --force"; fi
  export SUPERTONIC_DIR SUPERTONIC_VENV SUPERTONIC_PORT SUPERTONIC_BACKEND CONFIG_DIR
  SUPERTONIC_PLIST="$plist" "$SUPERTONIC_VENV/bin/python" - <<'PLISTPY'
import os, plistlib
from pathlib import Path
# Shell variables are supplied below through exported installer configuration.
c = os.environ
root = c['SUPERTONIC_DIR']
data = {
    'Label': 'com.opencode.supertonic',
    'ProgramArguments': [c['SUPERTONIC_VENV']+'/bin/python', '-m', 'uvicorn',
                         'local_voicemode_server:create_app', '--factory', '--host', '127.0.0.1',
                         '--port', c['SUPERTONIC_PORT'], '--app-dir', root],
    'EnvironmentVariables': {'HOME': c['HOME'], 'PATH': c['SUPERTONIC_VENV']+'/bin:/usr/bin:/bin',
                             'SUPERTONIC_MODEL_DIR': root+'/assets/supertonic-3',
                             'SUPERTONIC_ORT_BACKEND': c['SUPERTONIC_BACKEND'], 'ORT_DISABLE_TELEMETRY': '1'},
    'RunAtLoad': True, 'KeepAlive': True, 'WorkingDirectory': root,
    'StandardOutPath': c['CONFIG_DIR']+'/supertonic.log',
    'StandardErrorPath': c['CONFIG_DIR']+'/supertonic.log',
}
Path(c['SUPERTONIC_PLIST']).write_bytes(plistlib.dumps(data))
PLISTPY
  plutil -lint "$plist" >/dev/null
  ok "Supertonic launchd definition installed (backend=${SUPERTONIC_BACKEND})"
}
