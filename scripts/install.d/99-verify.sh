# shellcheck shell=bash
[[ "$SKIP_PARAKEET" == true ]] || wait_for_probe "Parakeet STT" 180 stt_probe_once "$CONFIG_DIR/parakeet-stt.log"
[[ "$SKIP_SUPERTONIC" == true ]] || wait_for_probe "Supertonic TTS" 240 tts_probe_once "$CONFIG_DIR/supertonic.log"

echo
info "── Setup verified successfully ──"
echo "  Voice skill:  $SKILL_DIR/talk.sh"
echo "  Doctor:       $SKILL_DIR/doctor.sh"
[[ "$SKIP_PARAKEET" == true ]] || echo "  STT API:      http://127.0.0.1:${PARAKEET_PORT}/v1/audio/transcriptions"
[[ "$SKIP_SUPERTONIC" == true ]] || echo "  TTS API:      http://127.0.0.1:${SUPERTONIC_PORT}/v1/audio/speech"
echo "  Re-check:     ./setup.sh --doctor"
