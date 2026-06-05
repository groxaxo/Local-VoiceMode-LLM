#!/bin/bash
# tts.sh — Multi-engine TTS CLI for OpenCode / talk skill.
#
# Engines: neutts (default), xai, vibevoice, supertonic.
# Set TTS_ENGINE to override. macOS say is intentionally not available.

set -e

# --- Engine config -----------------------------------------------------------
: "${TTS_ENGINE:=neutts}"
: "${XAI_API_KEY:=${XAI_API_KEY:-}}"
: "${XAI_TTS_VOICE:=eve}"
: "${XAI_TTS_MODEL:=grok-2-audio}"
: "${VIBEVOICE_WS_URI:=ws://127.0.0.1:8010/ws/tts}"
: "${VIBEVOICE_MODEL:=vibe-realtime-8bit}"
: "${VIBEVOICE_VOICE:=en-Emma_woman}"
: "${VIBEVOICE_VOICE_AUTO:=1}"
: "${VIBEVOICE_CFG_SCALE:=2.0}"
: "${VIBEVOICE_DDPM_STEPS:=15}"
: "${VIBEVOICE_SPEAK_PY:=$HOME/tts-multimodel-api/speak_vibevoice.py}"
: "${SUPERTONIC_URL:=http://127.0.0.1:8765}"
: "${SUPERTONIC_SH:=$HOME/.config/opencode/skills/supertonic-tts/supertonic.sh}"
: "${NEUTTS_URL:=http://127.0.0.1:8020}"
# NeuTTS model selection by language — must match NEUTTS_PRELOAD_MODELS
# to avoid lazy loading. Server preloads: q4-gguf (EN) + spanish-q4-gguf (ES)
: "${NEUTTS_MODEL:=neuphonic/neutts-nano-q4-gguf}"
: "${NEUTTS_MODEL_ES:=neuphonic/neutts-nano-spanish-q4-gguf}"
# -----------------------------------------------------------------------------

# shellcheck source=tts_lang.sh
. "${TTS_LANG_SH:=$HOME/.config/opencode/tts_lang.sh}"

TEXT="${1:-Hello.}"
OUTPUT="/tmp/opencode-speech.wav"
LANG="$(resolve_lang "${2:-}" "$TEXT")"

# If TTS_NO_PLAY=1, generate the WAV but don't play it (let caller handle playback)
: "${TTS_NO_PLAY:=0}"

speak_neutts() {
    local text="$1"
    local lang="$2"
    local model="$NEUTTS_MODEL"

    # Select preloaded model by language to avoid lazy loading
    case "$lang" in
        es*)  model="${NEUTTS_MODEL_ES}" ;;
        en*|*) model="${NEUTTS_MODEL}" ;;
    esac

    echo "[tts] NeuTTS lang=${lang} model=${model}" >&2

    local payload
    payload=$(python3 -c "
import json, sys
d = {'text': sys.argv[1], 'model': sys.argv[3]}
if sys.argv[2]:
    d['language'] = sys.argv[2]
print(json.dumps(d))
" "$text" "$lang" "$model" 2>/dev/null || printf '{"text":"%s","model":"%s"}' "$text" "$model")

    local http_code
    http_code=$(curl -sS -m 120 \
        -o "$OUTPUT" \
        -w '%{http_code}' \
        "${NEUTTS_URL}/v1/audio/speech" \
        -H "Content-Type: application/json" \
        -d "$payload") || {
        echo "tts.sh: NeuTTS request failed (curl exit $?)" >&2
        return 1
    }

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "tts.sh: NeuTTS HTTP $http_code" >&2
        rm -f "$OUTPUT"
        return 1
    fi

    [ -f "$OUTPUT" ] && [ -s "$OUTPUT" ] || { echo "tts.sh: NeuTTS produced no audio" >&2; return 1; }
    [ "$TTS_NO_PLAY" = "1" ] && { echo "$OUTPUT"; return 0; }
    afplay "$OUTPUT"
    rm -f "$OUTPUT"
}

speak_xai() {
    local text="$1"
    local lang="$2"
    local voice="${XAI_TTS_VOICE:-eve}"

    if [ -z "$XAI_API_KEY" ]; then
        echo "tts.sh: XAI_API_KEY not set" >&2
        return 1
    fi

    echo "[tts] xAI lang=${lang} voice=${voice}" >&2

    local input_json
    input_json=$(printf '{"text":%s,"voice_id":"%s","language":"%s"}' \
        "$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$text")" \
        "$voice" "$lang")

    local http_code
    http_code=$(curl -sS -m 60 \
        -o "$OUTPUT" \
        -w '%{http_code}' \
        "https://api.x.ai/v1/tts" \
        -H "Authorization: Bearer $XAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$input_json") || {
        echo "tts.sh: xAI request failed (curl exit $?)" >&2
        return 1
    }

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "tts.sh: xAI HTTP $http_code" >&2
        rm -f "$OUTPUT"
        return 1
    fi

    [ -f "$OUTPUT" ] && [ -s "$OUTPUT" ] || { echo "tts.sh: xAI produced no audio" >&2; return 1; }
    [ "$TTS_NO_PLAY" = "1" ] && { echo "$OUTPUT"; return 0; }
    afplay "$OUTPUT"
    rm -f "$OUTPUT"
}

speak_vibevoice() {
    local text="$1"
    local lang="$2"
    local py="${HOME}/tts-multimodel-api/venv/bin/python3"
    [ -x "$py" ] || py="${HOME}/.config/opencode/tts-venv/bin/python3"
    [ -x "$py" ] || py="python3"

    if [ ! -f "$VIBEVOICE_SPEAK_PY" ]; then
        echo "tts.sh: VibeVoice helper not found: $VIBEVOICE_SPEAK_PY" >&2
        return 1
    fi

    local voice
    voice="$(resolve_vibevoice_voice "$lang")"
    echo "[tts] VibeVoice lang=${lang} voice=${voice} (auto=${VIBEVOICE_VOICE_AUTO:-0})" >&2

    "$py" "$VIBEVOICE_SPEAK_PY" "$text" "$OUTPUT" \
        --uri "$VIBEVOICE_WS_URI" \
        --model "$VIBEVOICE_MODEL" \
        --language "$lang" \
        --voice "$voice" \
        --cfg-scale "$VIBEVOICE_CFG_SCALE" \
        --ddpm-steps "$VIBEVOICE_DDPM_STEPS" >/dev/null

    [ -f "$OUTPUT" ] || { echo "tts.sh: VibeVoice produced no wav" >&2; return 1; }
    [ "$TTS_NO_PLAY" = "1" ] && { echo "$OUTPUT"; return 0; }
    afplay "$OUTPUT"
    rm -f "$OUTPUT"
}

speak_supertonic() {
    local text="$1"
    local lang="$2"

    if [ ! -x "$SUPERTONIC_SH" ]; then
        echo "tts.sh: Supertonic wrapper not found: $SUPERTONIC_SH" >&2
        return 1
    fi

    echo "[tts] Supertonic lang=${lang} url=${SUPERTONIC_URL}" >&2

    local payload
    payload=$(python3 -c "
import json, sys
d = {'text': sys.argv[1]}
if sys.argv[2]:
    d['language'] = sys.argv[2]
print(json.dumps(d))
" "$text" "$lang" 2>/dev/null || printf '{"text":"%s"}' "$text")

    local http_code
    http_code=$(curl -sS -m 60 \
        -o "$OUTPUT" \
        -w '%{http_code}' \
        "${SUPERTONIC_URL}/v1/audio/speech" \
        -H "Content-Type: application/json" \
        -d "$payload") || {
        echo "tts.sh: Supertonic request failed (curl exit $?)" >&2
        return 1
    }

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "tts.sh: Supertonic HTTP $http_code" >&2
        rm -f "$OUTPUT"
        return 1
    fi

    [ -f "$OUTPUT" ] && [ -s "$OUTPUT" ] || { echo "tts.sh: Supertonic produced no audio" >&2; return 1; }
    [ "$TTS_NO_PLAY" = "1" ] && { echo "$OUTPUT"; return 0; }
    afplay "$OUTPUT"
    rm -f "$OUTPUT"
}

engine="$(printf '%s' "${TTS_ENGINE}" | tr '[:upper:]' '[:lower:]')"
case "$engine" in
    neutts|neuphonic)
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] NeuTTS failed, trying xAI fallback…" >&2
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] xAI failed, trying Supertonic…" >&2
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    xai)
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] xAI failed, trying NeuTTS fallback…" >&2
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] NeuTTS failed, trying VibeVoice…" >&2
        if speak_vibevoice "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    vibevoice|vibe|mlx-vibe)
        if speak_vibevoice "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] VibeVoice failed, trying NeuTTS fallback…" >&2
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] NeuTTS failed, trying xAI…" >&2
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    supertonic|coreml-tts)
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic failed, trying NeuTTS fallback…" >&2
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] NeuTTS failed, trying xAI…" >&2
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    *)
        echo "tts.sh: unknown TTS_ENGINE=${TTS_ENGINE}. Use: neutts, xai, vibevoice, supertonic." >&2
        exit 2
        ;;
esac
