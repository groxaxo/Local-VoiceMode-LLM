# shellcheck shell=bash
make_silence_wav() {
  python3 - "$1" <<'PY'
import sys, wave
with wave.open(sys.argv[1], 'wb') as wav:
    wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(16000)
    wav.writeframes(b'\0\0' * 4000)
PY
}
stt_probe_once() {
  local base="http://127.0.0.1:${PARAKEET_PORT}" tmp wav code rc=1
  tmp="$(mktemp "${TMPDIR:-/tmp}/lvml-stt.XXXXXX")"
  wav="$(mktemp "${TMPDIR:-/tmp}/lvml-stt-wav.XXXXXX")"
  code="$(curl -sS --max-time 4 -o "$tmp" -w '%{http_code}' "$base/healthz" || true)"
  if [[ "$code" == 200 ]]; then rc=0
  else
    code="$(curl -sS --max-time 4 -o "$tmp" -w '%{http_code}' "$base/health" || true)"
    if [[ "$code" == 200 ]] && grep -Eq '"ready"[[:space:]]*:[[:space:]]*true|"status"[[:space:]]*:[[:space:]]*"(ok|healthy)"' "$tmp"; then rc=0
    else
      make_silence_wav "$wav"
      code="$(curl -sS --max-time 30 -o "$tmp" -w '%{http_code}' \
        -F "file=@${wav};type=audio/wav" -F response_format=json \
        "$base/v1/audio/transcriptions" || true)"
      [[ "$code" == 200 ]] && grep -q '"text"' "$tmp" && rc=0
    fi
  fi
  rm -f "$tmp" "$wav"; return "$rc"
}
tts_probe_once() {
  local base="http://127.0.0.1:${SUPERTONIC_PORT}" tmp code rc=1
  tmp="$(mktemp "${TMPDIR:-/tmp}/lvml-tts.XXXXXX")"
  code="$(curl -sS --max-time 180 -o "$tmp" -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -d '{"model":"supertonic","input":"Voice setup test.","voice":"F3","response_format":"wav","stream":false}' \
    "$base/v1/audio/speech" || true)"
  if [[ "$code" == 200 && "$(wc -c < "$tmp")" -gt 1000 && "$(head -c 4 "$tmp")" == RIFF ]]; then rc=0; fi
  rm -f "$tmp"; return "$rc"
}
supertonic_backend_once() {
  local base="http://127.0.0.1:${SUPERTONIC_PORT}" tmp code
  tmp="$(mktemp "${TMPDIR:-/tmp}/lvml-tts-health.XXXXXX")"
  code="$(curl -sS --max-time 8 -o "$tmp" -w '%{http_code}' "$base/health" || true)"
  if [[ "$code" != 200 ]]; then rm -f "$tmp"; return 1; fi
  python3 - "$tmp" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    payload = json.load(f)
backend = payload.get("backend")
if not isinstance(backend, str) or not backend.strip():
    raise SystemExit(1)
print(backend.strip().lower())
PY
  local rc=$?
  rm -f "$tmp"
  return "$rc"
}
wait_for_probe() {
  local label="$1" timeout="$2" probe="$3" log="$4" elapsed=0
  info "Waiting for $label readiness..."
  until "$probe"; do
    if (( elapsed >= timeout )); then
      err "$label did not become ready within ${timeout}s"
      [[ -f "$log" ]] && tail -n 40 "$log" >&2 || true
      return 1
    fi
    sleep 3; elapsed=$((elapsed + 3))
  done
  ok "$label passed its end-to-end API probe"
}
show_doctor() {
  local failed=0 backend
  echo; info "── Voice service diagnosis ──"
  if [[ "$SKIP_PARAKEET" == false ]]; then stt_probe_once && ok "STT :${PARAKEET_PORT} works" || { err "STT :${PARAKEET_PORT} failed"; failed=1; }; fi
  if [[ "$SKIP_SUPERTONIC" == false ]]; then
    if tts_probe_once; then
      ok "TTS :${SUPERTONIC_PORT} works"
      backend="$(supertonic_backend_once || true)"
      [[ -n "$backend" ]] && ok "Supertonic runtime backend: $backend" || warn "Supertonic backend could not be read from /health"
    else
      err "TTS :${SUPERTONIC_PORT} failed"; failed=1
    fi
  fi
  if [[ "$PLATFORM" == macos ]]; then
    local label
    for label in com.opencode.parakeet-stt com.opencode.supertonic; do
      launchd_loaded "$label" && ok "launchd loaded: $label" || warn "launchd not loaded: $label"
    done
  fi
  return "$failed"
}
