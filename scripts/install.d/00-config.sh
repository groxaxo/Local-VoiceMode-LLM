# shellcheck shell=bash
CONFIG_DIR="${VOICE_CONFIG_DIR:-${HOME}/.config/opencode}"
SKILL_DIR="${CONFIG_DIR}/skills/talk"
VENV_DIR="${CONFIG_DIR}/tts-venv"
PARAKEET_DIR="${CONFIG_DIR}/parakeet-stt"
PARAKEET_VENV="${PARAKEET_DIR}/.venv"
SUPERTONIC_DIR="${CONFIG_DIR}/supertonic-tts"
SUPERTONIC_VENV="${SUPERTONIC_DIR}/.venv"
PARAKEET_PORT="${PARAKEET_PORT:-5093}"
SUPERTONIC_PORT="${SUPERTONIC_PORT:-8766}"
LAUNCHD_DIR="${HOME}/Library/LaunchAgents"
OS="$(uname -s 2>/dev/null || printf unknown)"
ARCH="$(uname -m 2>/dev/null || printf unknown)"
UID_NUM="$(id -u)"
case "$OS" in Darwin) PLATFORM=macos ;; Linux) PLATFORM=linux ;; *) PLATFORM=other ;; esac

info() { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[setup]\033[0m ✓ %s\n' "$*"; }
warn() { printf '\033[1;33m[setup]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[setup]\033[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }
on_error() {
  local rc=$?
  err "Installation stopped at line ${BASH_LINENO[0]} (exit ${rc})."
  err "The selected stack was not reported as successful because it was not verified."
  exit "$rc"
}
trap on_error ERR

SKIP_PARAKEET=false
SKIP_SUPERTONIC=false
SKIP_VOICES=false
VENV_ONLY=false
FORCE=false
UNINSTALL=false
DOCTOR_ONLY=false
ACCEL_CHOICE=auto
INTEGRATE_CLAUDECODE=true
INTEGRATE_OPENCODE=true
INTEGRATE_OPENCLAW=true
INTEGRATE_HERMES=true
INTEGRATE_CODEX=true
INTEGRATIONS_ARG=""

usage() {
  cat <<'USAGE'
Usage: ./setup.sh [options]

Installs or repairs the local voice stack and verifies it end to end.

  --skip-parakeet       Do not install or verify Parakeet STT
  --skip-supertonic     Do not install or verify Supertonic TTS
  --skip-voices         Skip optional macOS reference voice generation
  --venv-only           Install only the shared voice Python environment
  --gpu                  Use NVIDIA CUDA on supported Linux hosts
  --cpu                  Force CPU execution
  --force, -f            Replace conflicting managed service definitions
  --doctor               Diagnose currently installed services only
  --uninstall            Stop services; add --force to remove managed files
  --integrations=LIST    claudecode,opencode,openclaw,hermes,codex
  --no-integrations      Do not install agent skills
  -h, --help             Show this help
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --skip-parakeet) SKIP_PARAKEET=true ;;
    --skip-supertonic) SKIP_SUPERTONIC=true ;;
    --skip-voices) SKIP_VOICES=true ;;
    --venv-only) VENV_ONLY=true ;;
    --gpu) ACCEL_CHOICE=gpu ;;
    --cpu) ACCEL_CHOICE=cpu ;;
    --force|-f) FORCE=true ;;
    --doctor) DOCTOR_ONLY=true ;;
    --uninstall) UNINSTALL=true ;;
    --integrations=*) INTEGRATIONS_ARG="${arg#--integrations=}" ;;
    --no-integrations)
      INTEGRATE_CLAUDECODE=false; INTEGRATE_OPENCODE=false
      INTEGRATE_OPENCLAW=false; INTEGRATE_HERMES=false; INTEGRATE_CODEX=false ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $arg (run ./setup.sh --help)" ;;
  esac
done

if [[ -n "$INTEGRATIONS_ARG" ]]; then
  INTEGRATE_CLAUDECODE=false; INTEGRATE_OPENCODE=false
  INTEGRATE_OPENCLAW=false; INTEGRATE_HERMES=false; INTEGRATE_CODEX=false
  IFS=',' read -r -a integrations <<< "$INTEGRATIONS_ARG"
  for integration in "${integrations[@]}"; do
    case "$integration" in
      claudecode) INTEGRATE_CLAUDECODE=true ;; opencode) INTEGRATE_OPENCODE=true ;;
      openclaw) INTEGRATE_OPENCLAW=true ;; hermes) INTEGRATE_HERMES=true ;;
      codex) INTEGRATE_CODEX=true ;; *) die "Unknown integration: $integration" ;;
    esac
  done
fi

ask_yn() {
  local prompt="$1" default="${2:-y}" answer
  if [[ "$default" == y ]]; then printf '  %s [Y/n]: ' "$prompt"; else printf '  %s [y/N]: ' "$prompt"; fi
  read -r answer
  case "${answer:-$default}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

if [[ $# -eq 0 && -t 0 && -t 1 ]]; then
  printf '\n\033[1;36m  Local VoiceMode LLM — verified setup\033[0m\n\n'
  ask_yn "Parakeet STT on :${PARAKEET_PORT}" y || SKIP_PARAKEET=true
  ask_yn "Supertonic TTS on :${SUPERTONIC_PORT}" y || SKIP_SUPERTONIC=true
  echo
  ask_yn "Install Claude Code skill" y || INTEGRATE_CLAUDECODE=false
  ask_yn "Install OpenCode skill" y || INTEGRATE_OPENCODE=false
  ask_yn "Install OpenClaw skill" y || INTEGRATE_OPENCLAW=false
  ask_yn "Install Hermes skill" y || INTEGRATE_HERMES=false
  ask_yn "Install Codex skill" y || INTEGRATE_CODEX=false
  echo
fi
