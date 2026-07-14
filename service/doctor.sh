#!/usr/bin/env bash
# Diagnose the installed Local-VoiceMode-LLM services with real API probes.
set -uo pipefail

PARAKEET_PORT="${PARAKEET_PORT:-5093}"
SUPERTONIC_PORT="${SUPERTONIC_PORT:-8766}"
CONFIG_DIR="${VOICE_CONFIG_DIR:-${HOME}/.config/opencode}"
OS="$(uname -s 2>/dev/null || printf unknown)"
UID_NUM="$(id -u)"

ok()   { printf '\033[1;32m[doctor]\033[0m ✓ %s\n' "$*"; }
warn() { printf '\033[1;33m[doctor]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[doctor]\033[0m %s\n' "$*" >&2; }

command -v curl >/dev/null 2>&1 || { err "curl is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { err "python3 is required"; exit 1; }

make_silence_wav() {
  python3 - "$1" <<'PY'
import sys, wave
with wave.open(sys.argv[1], 'wb') as wav:
    wav.setnchannels(1)
    wav.setsampwidth(2)
    wav.setframerate(16000)
    wav.writeframes(b'\0\0' * 4000)
PY
}

check_stt() {
  local base="http://127.0.0.1:${PARAKEET_PORT}" tmp wav code rc=1
  tmp="$(mktemp)"
  wav="$(mktemp "${TMPDIR:-/tmp}/lvml-doctor-stt.XXXXXX")"

  code="$(curl -sS --max-time 4 -o "$tmp" -w '%{http_code}' "$base/healthz" || true)"
  if [[ "$code" == 200 ]]; then
    rc=0
  else
    code="$(curl -sS --max-time 4 -o "$tmp" -w '%{http_code}' "$base/health" || true)"
    if [[ "$code" == 200 ]] && grep -Eq '"ready"[[:space:]]*:[[:space:]]*true|"status"[[:space:]]*:[[:space:]]*"(ok|healthy)"' "$tmp"; then
      rc=0
    else
      make_silence_wav "$wav"
      code="$(curl -sS --max-time 30 -o "$tmp" -w '%{http_code}' \
        -F "file=@${wav};type=audio/wav" -F 'response_format=json' \
        "$base/v1/audio/transcriptions" || true)"
      if [[ "$code" == 200 ]] && grep -q '"text"' "$tmp"; then rc=0; fi
    fi
  fi

  rm -f "$tmp" "$wav"
  return "$rc"
}

check_tts() {
  local base="http://127.0.0.1:${SUPERTONIC_PORT}" tmp code rc=1
  tmp="$(mktemp "${TMPDIR:-/tmp}/lvml-doctor-tts.XXXXXX")"
  code="$(curl -sS --max-time 180 -o "$tmp" -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -d '{"model":"supertonic","input":"Voice doctor test.","voice":"F3","response_format":"wav","stream":false}' \
    "$base/v1/audio/speech" || true)"
  if [[ "$code" == 200 && "$(wc -c < "$tmp")" -gt 1000 && "$(head -c 4 "$tmp")" == RIFF ]]; then rc=0; fi
  rm -f "$tmp"
  return "$rc"
}

show_launchd() {
  [[ "$OS" == Darwin ]] || return 0
  if ! command -v launchctl >/dev/null 2>&1; then return 0; fi
  local label
  for label in com.opencode.parakeet-stt com.opencode.supertonic; do
    if launchctl print "gui/${UID_NUM}/${label}" >/dev/null 2>&1; then
      ok "launchd loaded: $label"
    else
      warn "launchd not loaded: $label"
    fi
  done
  if launchctl print "gui/${UID_NUM}/com.opencode.tts-server" >/dev/null 2>&1; then
    warn "Legacy Chatterbox service is also loaded on its own port; it is separate from Supertonic."
  fi
}

failed=0
printf '\nLocal VoiceMode service diagnosis\n\n'
show_launchd

if check_stt; then
  ok "STT transcription API works on :${PARAKEET_PORT}"
else
  err "STT transcription API failed on :${PARAKEET_PORT}"
  [[ -f "$CONFIG_DIR/parakeet-stt.log" ]] && tail -n 25 "$CONFIG_DIR/parakeet-stt.log" >&2
  failed=1
fi

if check_tts; then
  ok "Supertonic generated a valid WAV on :${SUPERTONIC_PORT}"
else
  err "Supertonic synthesis failed on :${SUPERTONIC_PORT}"
  [[ -f "$CONFIG_DIR/supertonic.log" ]] && tail -n 25 "$CONFIG_DIR/supertonic.log" >&2
  failed=1
fi

if [[ "$failed" -eq 0 ]]; then
  ok "All selected local voice services are operational"
else
  err "Repair from the repository with: ./setup.sh --force"
fi
exit "$failed"
