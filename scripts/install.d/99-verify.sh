# shellcheck shell=bash
[[ "$SKIP_PARAKEET" == true ]] || wait_for_probe "Parakeet STT" 180 stt_probe_once "$CONFIG_DIR/parakeet-stt.log"

if [[ "$SKIP_PARAKEET" == false && "$STT_BACKEND" != onnx ]]; then
  curl -fsS --max-time 8 "http://127.0.0.1:${PARAKEET_PORT}/health" | python3 -c '
import json, sys
payload=json.load(sys.stdin)
if payload.get("ready") is not True or payload.get("backend") != sys.argv[1]:
    raise SystemExit("Selected MLX STT backend did not match the running service")
' "$STT_BACKEND"
  ok "MLX STT backend verified: $STT_BACKEND"
fi

SUPERTONIC_ACTIVE_BACKEND=""
if [[ "$SKIP_SUPERTONIC" == false ]]; then
  wait_for_probe "Supertonic TTS" 300 tts_probe_once "$CONFIG_DIR/supertonic.log"
  SUPERTONIC_ACTIVE_BACKEND="$(supertonic_backend_once || true)"
  [[ -n "$SUPERTONIC_ACTIVE_BACKEND" ]] || die "Supertonic generated audio but /health did not report its runtime backend"
  [[ "$SUPERTONIC_ACTIVE_BACKEND" == "$SUPERTONIC_BACKEND" ]] || die "Requested backend=${SUPERTONIC_BACKEND}, reported ${SUPERTONIC_ACTIVE_BACKEND}"
  ok "Supertonic runtime backend: ${SUPERTONIC_ACTIVE_BACKEND}"
fi

echo
info "── Setup verified successfully ──"
echo "  Voice skill:  $SKILL_DIR/talk.sh"
echo "  Doctor:       $SKILL_DIR/doctor.sh"
[[ "$SKIP_PARAKEET" == true ]] || echo "  STT API:      http://127.0.0.1:${PARAKEET_PORT}/v1/audio/transcriptions"
[[ "$SKIP_SUPERTONIC" == true ]] || echo "  TTS API:      http://127.0.0.1:${SUPERTONIC_PORT}/v1/audio/speech (${SUPERTONIC_ACTIVE_BACKEND})"
echo "  Re-check:     ./setup.sh --doctor"
