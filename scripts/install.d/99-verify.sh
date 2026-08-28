# shellcheck shell=bash
[[ "$SKIP_PARAKEET" == true ]] || wait_for_probe "Parakeet STT" 180 stt_probe_once "$CONFIG_DIR/parakeet-stt.log"

SUPERTONIC_ACTIVE_BACKEND=""
if [[ "$SKIP_SUPERTONIC" == false ]]; then
  wait_for_probe "Supertonic TTS" 300 tts_probe_once "$CONFIG_DIR/supertonic.log"
  SUPERTONIC_ACTIVE_BACKEND="$(supertonic_backend_once || true)"
  [[ -n "$SUPERTONIC_ACTIVE_BACKEND" ]] || die "Supertonic generated audio but /health did not report its runtime backend"
  case "$SUPERTONIC_BACKEND" in
    mlx)
      [[ "$SUPERTONIC_ACTIVE_BACKEND" == mlx ]] || die "Strict MLX was requested, but Supertonic reported backend=${SUPERTONIC_ACTIVE_BACKEND}"
      ok "Supertonic runtime backend: mlx"
      ;;
    auto)
      if [[ "$SUPERTONIC_ACTIVE_BACKEND" == mlx ]]; then
        ok "Supertonic runtime backend: mlx (Apple Silicon default)"
      elif [[ "$SUPERTONIC_ACTIVE_BACKEND" == cpu ]]; then
        warn "Supertonic MLX could not initialize; verified ONNX CPU fallback is active"
      else
        warn "Supertonic auto-selected backend: ${SUPERTONIC_ACTIVE_BACKEND}"
      fi
      ;;
    *) ok "Supertonic runtime backend: ${SUPERTONIC_ACTIVE_BACKEND}" ;;
  esac
fi

echo
info "── Setup verified successfully ──"
echo "  Voice skill:  $SKILL_DIR/talk.sh"
echo "  Doctor:       $SKILL_DIR/doctor.sh"
[[ "$SKIP_PARAKEET" == true ]] || echo "  STT API:      http://127.0.0.1:${PARAKEET_PORT}/v1/audio/transcriptions"
[[ "$SKIP_SUPERTONIC" == true ]] || echo "  TTS API:      http://127.0.0.1:${SUPERTONIC_PORT}/v1/audio/speech (${SUPERTONIC_ACTIVE_BACKEND})"
echo "  Re-check:     ./setup.sh --doctor"
