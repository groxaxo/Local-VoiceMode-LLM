# shellcheck shell=bash
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
retry() {
  local attempts="$1" delay="$2" n=1; shift 2
  until "$@"; do
    (( n >= attempts )) && return 1
    warn "Command failed (attempt ${n}/${attempts}); retrying..."
    sleep "$delay"
    n=$((n + 1))
  done
}
python_for_venv() {
  if command -v python3.12 >/dev/null 2>&1; then printf '%s\n' python3.12
  elif command -v python3 >/dev/null 2>&1; then printf '%s\n' python3
  else return 1; fi
}
create_venv() {
  local target="$1" label="$2" py
  py="$(python_for_venv)" || die "Python 3.11+ is required"
  if [[ -x "$target/bin/python" ]]; then
    if "$target/bin/python" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,11) else 1)'; then
      info "$label venv exists at $target"; return 0
    fi
    warn "$label venv uses unsupported Python; recreating"
    rm -rf "$target"
  elif [[ -e "$target" ]]; then
    warn "$label venv is incomplete; recreating"
    rm -rf "$target"
  fi
  mkdir -p "$(dirname "$target")"
  if command -v uv >/dev/null 2>&1; then uv venv --seed --python "$py" "$target"; else "$py" -m venv "$target"; fi
  "$target/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || true
  [[ -x "$target/bin/python" ]] || die "Could not create $label venv"
  ok "$label venv created"
}
pip_install() { local python="$1"; shift; retry 3 2 "$python" -m pip install --disable-pip-version-check "$@"; }
validate_imports() {
  local python="$1" label="$2"; shift 2
  "$python" - "$@" <<'PY'
import importlib, sys
errors=[]
for name in sys.argv[1:]:
    try: importlib.import_module(name)
    except Exception as exc: errors.append(f"{name}: {exc}")
if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY
  ok "$label Python imports validated"
}

HAS_NVIDIA=false
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then HAS_NVIDIA=true; fi
ACCEL=cpu
if [[ "$ACCEL_CHOICE" == gpu ]]; then
  if [[ "$PLATFORM" == linux && "$HAS_NVIDIA" == true ]]; then ACCEL=cuda
  else warn "CUDA is unavailable here; using CPU"; fi
elif [[ "$ACCEL_CHOICE" == auto && "$PLATFORM" == linux && "$HAS_NVIDIA" == true && -t 0 && -t 1 ]]; then
  ask_yn "Use NVIDIA CUDA for voice services?" n && ACCEL=cuda
fi
USE_GPU=false; ORT_BACKEND=cpu
if [[ "$ACCEL" == cuda ]]; then USE_GPU=true; ORT_BACKEND=cuda; fi
mkdir -p "$CONFIG_DIR"
[[ "$PLATFORM" == macos ]] && mkdir -p "$LAUNCHD_DIR"

launchd_loaded() { launchctl print "gui/${UID_NUM}/$1" >/dev/null 2>&1; }
launchd_stop() {
  local label="$1" plist="$2"
  launchctl bootout "gui/${UID_NUM}/${label}" >/dev/null 2>&1 \
    || launchctl bootout "gui/${UID_NUM}" "$plist" >/dev/null 2>&1 || true
}

uninstall_stack() {
  info "Stopping Local VoiceMode services"
  if [[ "$PLATFORM" == macos ]]; then
    local label plist
    for label in com.opencode.parakeet-stt com.opencode.supertonic; do
      plist="$LAUNCHD_DIR/$label.plist"
      [[ -f "$plist" ]] && launchd_stop "$label" "$plist"
      [[ "$FORCE" == true && -f "$plist" ]] && rm -f "$plist"
    done
  elif [[ "$PLATFORM" == linux ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now opencode-parakeet-stt.service opencode-supertonic.service >/dev/null 2>&1 || true
  fi
  if [[ "$FORCE" == true ]]; then
    rm -rf "$PARAKEET_DIR" "$SUPERTONIC_DIR" "$VENV_DIR" "$SKILL_DIR"
    ok "Managed files removed"
  else
    warn "Files preserved; use --uninstall --force to remove them"
  fi
}
