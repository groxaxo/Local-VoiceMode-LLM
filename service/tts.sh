#!/bin/bash
# tts.sh — Multi-engine TTS CLI for OpenCode / talk skill.
#
# Local engines:  supertonic (repo default) · qwen (MLX) · neutts
# Remote engines (for slow CPUs): openai (any OpenAI-compatible /v1/audio/speech),
#                  inworld (expressive, per-sentence steering), xai (last resort).
# Set TTS_ENGINE to override. With a LOCAL primary, the local engines are always
# tried before any cloud. Choosing a remote engine (openai/inworld/xai) honors that
# choice first, then still falls back to local. macOS `say` is intentionally not used.
#
# Slow CPU? Point TTS_ENGINE=openai at any OpenAI-compatible endpoint (OpenAI, a
# hosted provider, or your own remote box) to offload synthesis. See docs/providers.md.

set -e

# Cross-platform WAV playback (macOS afplay, Linux ffplay/aplay/paplay)
play_wav() {
    local f="$1"
    [ -f "$f" ] || return 1
    case "$(uname -s 2>/dev/null)" in
        Darwin) afplay "$f" ;;
        *)
            if command -v ffplay &>/dev/null; then
                ffplay -nodisp -autoexit -loglevel quiet "$f" 2>/dev/null
            elif command -v aplay &>/dev/null; then
                aplay -q "$f" 2>/dev/null
            elif command -v paplay &>/dev/null; then
                paplay "$f" 2>/dev/null
            else
                echo "[tts] No audio player found (install ffmpeg)" >&2; return 1
            fi ;;
    esac
}

# Apply a short fade-in/out to a WAV in place to kill onset/offset clicks.
# Inworld (and some neural TTS) clips start on a non-zero sample — the first
# sample jumps straight to ~60-99% of peak, an audible pop at the start of
# every chunk/phrase. A few ms of fade ramps that to zero. Idempotent and
# cheap; safe to call on any mono/stereo 8/16/32-bit PCM WAV.
: "${TTS_FADE_MS:=6}"
fade_wav_edges() {
    local f="$1" ms="${2:-${TTS_FADE_MS:-6}}"
    [ -f "$f" ] || return 1
    [ "$ms" = "0" ] && return 0
    python3 - "$f" "$ms" <<'PY' 2>/dev/null || return 0
import wave, struct, sys
path, ms = sys.argv[1], float(sys.argv[2])
try:
    with wave.open(path, 'rb') as w:
        params = w.getparams()
        frames = w.readframes(w.getnframes())
except Exception:
    sys.exit(0)
sw = params.sampwidth
fmt = {1:'b', 2:'h', 4:'i'}.get(sw)
if fmt is None:
    sys.exit(0)
n = len(frames) // sw
samples = list(struct.unpack(f'<{n}{fmt}', frames))
ch = max(1, params.nchannels)
fade_n = int(params.framerate * ms / 1000.0) * ch   # ramp length in samples
if fade_n > 0 and n > fade_n * 2:
    for i in range(fade_n):
        g = i / fade_n
        samples[i] = int(samples[i] * g)
        samples[-(i+1)] = int(samples[-(i+1)] * g)
    with wave.open(path, 'wb') as w:
        w.setparams(params)
        w.writeframes(struct.pack(f'<{n}{fmt}', *samples))
PY
}

# --- Engine config -----------------------------------------------------------
# Default engine is `supertonic` (zero-setup, on-device, no API key). The other
# engines are OPTIONAL — opt in with TTS_ENGINE=<name>:
#   qwen      — local MLX Qwen3-TTS server (Apple Silicon). Setup/server:
#               https://github.com/groxaxo/Qwen3-TTS-Openai-Fastapi
#   neutts    — local NeuTTS GGUF server
#   inworld   — Inworld AI cloud (needs INWORLD_API_KEY / INWORLD_TTS_API)
#   xai       — xAI Grok cloud (needs XAI_API_KEY); last-resort fallback
: "${TTS_ENGINE:=supertonic}"
# Qwen3-TTS — local MLX server (Apple Silicon), OpenAI-compatible
# /v1/audio/speech. Native voices: serena, vivian, uncle_fu, ryan, aiden,
# ono_anna, sohee, eric, dylan (OpenAI aliases alloy/nova/… also accepted).
# The model auto-detects language, so no lang_code is sent. WAV keeps latency
# low (no mp3/pydub encode step).
# Server + setup: https://github.com/groxaxo/Qwen3-TTS-Openai-Fastapi
#
# Three CustomVoice MLX servers (see the Qwen3-TTS repo above):
#   fast → 0.6B on :18881 (low latency)     hq → 1.7B on :18882 (always-on)
#   lazy → 1.7B on :18883 (auto-start, 5-min idle timeout, frees VRAM when idle)
# QWEN_TTS_QUALITY=fast|hq|lazy picks which. An explicit QWEN_TTS_URL overrides.
: "${QWEN_TTS_URL_FAST:=http://127.0.0.1:18881}"
: "${QWEN_TTS_URL_HQ:=http://127.0.0.1:18882}"
: "${QWEN_TTS_URL_LAZY:=http://127.0.0.1:18883}"
: "${QWEN_TTS_QUALITY:=hq}"
# Optional helper that lazily starts the :18883 server (see the Qwen3-TTS repo).
# Override with QWEN_TTS_LAZY_ENSURE_SH; if absent, qwen-lazy degrades gracefully.
: "${QWEN_TTS_LAZY_ENSURE_SH:=$HOME/Qwen3-TTS-Openai-Fastapi/qwen-lazy-ensure.sh}"
if [ -z "${QWEN_TTS_URL:-}" ]; then
    case "$(printf '%s' "$QWEN_TTS_QUALITY" | tr '[:upper:]' '[:lower:]')" in
        hq|high|best|1.7b|large)  QWEN_TTS_URL="$QWEN_TTS_URL_HQ" ;;
        lazy|lazy-1.7b|qwen-lazy) QWEN_TTS_URL="$QWEN_TTS_URL_LAZY" ;;
        *)                        QWEN_TTS_URL="$QWEN_TTS_URL_FAST" ;;
    esac
fi
: "${QWEN_TTS_VOICE:=vivian}"
: "${QWEN_TTS_MODEL:=qwen3-tts}"
: "${QWEN_TTS_SPEED:=1.0}"
: "${XAI_API_KEY:=${XAI_API_KEY:-}}"
: "${XAI_TTS_VOICE:=eve}"
: "${XAI_TTS_MODEL:=grok-2-audio}"
: "${SUPERTONIC_URL:=http://127.0.0.1:8765}"
: "${SUPERTONIC_SH:=$HOME/.config/opencode/skills/supertonic-tts/supertonic.sh}"
: "${SUPERTONIC_VOICE:=F4}"   # Supertonic 3 voices: F1–F5 / M1–M5 (default F4)
# Quality presets: normal = 8 steps (fast), high = 20 steps (best). Set
# TTS_QUALITY=high for HQ, or override SUPERTONIC_STEPS=<1-20> directly (wins).
: "${TTS_QUALITY:=high}"
case "$(printf '%s' "${TTS_QUALITY}" | tr '[:upper:]' '[:lower:]')" in
    high|hq|best) _q_steps=20 ;;
    *)            _q_steps=8  ;;
esac
: "${SUPERTONIC_STEPS:=$_q_steps}"   # denoising steps (1–20)
: "${SUPERTONIC_SPEED:=1.0}"
: "${NEUTTS_URL:=http://127.0.0.1:8020}"
: "${NEUTTS_MODEL:=neuphonic/neutts-nano-q8-gguf}"
: "${NEUTTS_MODEL_ES:=neuphonic/neutts-nano-spanish-q8-gguf}"
: "${NEUTTS_MODEL_DE:=neuphonic/neutts-nano-german-q8-gguf}"
: "${NEUTTS_MODEL_FR:=neuphonic/neutts-nano-french-q8-gguf}"
# Inflect-Nano-v1 — ultra-small local CPU TTS (4.63M params, English-only, male voice "mark").
# 10-13x realtime. Experimental quality. English-only (bails on other languages).
: "${INFLECT_URL:=http://127.0.0.1:8030}"
# Generic OpenAI-compatible remote TTS (for slow CPUs / no local backend). Works
# with OpenAI's own /v1/audio/speech, a hosted provider, or your own remote box
# running any OpenAI-compatible speech server. Defaults target OpenAI; override
# OPENAI_TTS_URL for other providers. See docs/providers.md.
: "${OPENAI_TTS_URL:=https://api.openai.com/v1}"
: "${OPENAI_TTS_KEY:=${OPENAI_API_KEY:-}}"
: "${OPENAI_TTS_MODEL:=gpt-4o-mini-tts}"
: "${OPENAI_TTS_VOICE:=alloy}"
: "${OPENAI_TTS_FORMAT:=wav}"
# Inworld TTS (cloud, Basic auth). Model: inworld-tts-2 / inworld-tts-2-max.
# Voice: built-ins like Ashley, Dennis, Mark, Olivia, etc. (see list-voices API).
# Requires INWORLD_API_KEY env var. Get a key: https://platform.inworld.ai/api-keys
: "${INWORLD_TTS_VOICE:=Ashley}"
: "${INWORLD_TTS_MODEL:=inworld-tts-2}"
: "${INWORLD_TTS_URL:=https://api.inworld.ai/tts/v1/voice}"
# Inworld returns LINEAR16 by default at 48 kHz mono — playable by afplay/ffplay.
: "${INWORLD_TTS_ENCODING:=LINEAR16}"
: "${INWORLD_TTS_SAMPLE_RATE:=48000}"
# Accept either INWORLD_API_KEY or INWORLD_TTS_API (some shells export the latter).
: "${INWORLD_API_KEY:=${INWORLD_TTS_API:-}}"
# -----------------------------------------------------------------------------

# shellcheck source=tts_lang.sh
. "${TTS_LANG_SH:=$HOME/.config/opencode/tts_lang.sh}"

TEXT="${1:-Hello.}"
OUTPUT="/tmp/opencode-speech.wav"
LANG="$(resolve_lang "${2:-}" "$TEXT")"

: "${TTS_NO_PLAY:=0}"

speak_neutts() {
    local text="$1"
    local lang="$2"
    local model="$NEUTTS_MODEL"

    case "$lang" in
        es*)  model="${NEUTTS_MODEL_ES}" ;;
        de*)  model="${NEUTTS_MODEL_DE}" ;;
        fr*)  model="${NEUTTS_MODEL_FR}" ;;
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
    play_wav "$OUTPUT"
    rm -f "$OUTPUT"
}

speak_inflect() {
    local text="$1"
    local lang="$2"

    # Inflect-Nano is English-only — bail on non-English so the fallback chain handles it
    case "$lang" in
        en*) ;;
        *) echo "[tts] Inflect-Nano is English-only, skipping (lang=${lang})" >&2; return 1 ;;
    esac

    echo "[tts] Inflect-Nano lang=${lang}" >&2

    local payload
    payload=$(python3 -c "
import json, sys
print(json.dumps({'text': sys.argv[1]}))
" "$text" 2>/dev/null || printf '{"text":"%s"}' "$text")

    local http_code
    http_code=$(curl -sS -m 60 \
        -o "$OUTPUT" \
        -w '%{http_code}' \
        "${INFLECT_URL}/v1/audio/speech" \
        -H "Content-Type: application/json" \
        -d "$payload") || {
        echo "tts.sh: Inflect-Nano request failed (curl exit $?)" >&2
        return 1
    }

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "tts.sh: Inflect-Nano HTTP $http_code" >&2
        rm -f "$OUTPUT"
        return 1
    fi

    [ -f "$OUTPUT" ] && [ -s "$OUTPUT" ] || { echo "tts.sh: Inflect-Nano produced no audio" >&2; return 1; }
    [ "$TTS_NO_PLAY" = "1" ] && { echo "$OUTPUT"; return 0; }
    play_wav "$OUTPUT"
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

    # TTS_NO_PLAY (barge-in mode) — use single-request path
    if [ "${TTS_NO_PLAY:-0}" = "1" ]; then
        _speak_xai_single "$text" "$lang" "$voice"
        return $?
    fi

    # Split into sentence chunks on . ! ?
    local chunks_json
    chunks_json=$(python3 -c "
import sys, re, json
text = sys.stdin.read().strip()
parts = re.split(r'(?<=[.!?])\s+', text)
merged, buf = [], ''
for p in parts:
    p = p.strip()
    if not p:
        continue
    if buf:
        buf = buf + ' ' + p
    else:
        buf = p
    if len(buf.split()) >= 2:
        merged.append(buf)
        buf = ''
if buf:
    if merged:
        merged[-1] = merged[-1] + ' ' + buf
    else:
        merged.append(buf)
print(json.dumps(merged))
" <<<"$text")

    local count
    count=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$chunks_json")

    if [ "$count" -le 1 ]; then
        _speak_xai_single "$text" "$lang" "$voice"
        return $?
    fi

    echo "[tts] Chunking into $count sentences (parallel xAI)" >&2
    _speak_xai_chunked "$chunks_json" "$count" "$lang" "$voice"
}

_speak_xai_single() {
    local text="$1"
    local lang="$2"
    local voice="$3"

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
    play_wav "$OUTPUT"
    rm -f "$OUTPUT"
}

_speak_xai_chunked() {
    local chunks_json="$1"
    local count="$2"
    local lang="$3"
    local voice="$4"

    local chunk_dir
    chunk_dir=$(mktemp -d /tmp/opencode-tts-chunks.XXXXXX)

    # Fire all chunk TTS requests in parallel
    local i chunk_text wav_prefix
    for ((i=0; i<count; i++)); do
        chunk_text=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])[$i])" "$chunks_json")
        wav_prefix="${chunk_dir}/chunk_$(printf '%03d' $i)"
        (
            input_json=$(printf '{"text":%s,"voice_id":"%s","language":"%s"}' \
                "$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$chunk_text")" \
                "$voice" "$lang")
            if curl -sS -m 30 -o "${wav_prefix}.wav" \
                "https://api.x.ai/v1/tts" \
                -H "Authorization: Bearer $XAI_API_KEY" \
                -H "Content-Type: application/json" \
                -d "$input_json" 2>/dev/null && [ -f "${wav_prefix}.wav" ] && [ -s "${wav_prefix}.wav" ]; then
                touch "${wav_prefix}.ready"
            else
                echo "[tts] xAI chunk $i failed" >&2
                touch "${wav_prefix}.failed"
            fi
        ) &
    done

    # Play in order — starts faster vs single-path, may still wait for late chunks
    for ((i=0; i<count; i++)); do
        wav_prefix="${chunk_dir}/chunk_$(printf '%03d' $i)"
        while [ ! -f "${wav_prefix}.ready" ] && [ ! -f "${wav_prefix}.failed" ]; do
            sleep 0.05
        done
        if [ -f "${wav_prefix}.ready" ]; then
            play_wav "${wav_prefix}.wav"
        fi
    done

    rm -rf "$chunk_dir"
    return 0
}

speak_supertonic() {
    local text="$1"
    local lang="$2"

    echo "[tts] Supertonic voice=${SUPERTONIC_VOICE} steps=${SUPERTONIC_STEPS} (${TTS_QUALITY}) lang=${lang} url=${SUPERTONIC_URL}" >&2

    # Supertonic Express 3 exposes an OpenAI-compatible /v1/audio/speech endpoint:
    # required field is `input`; voice is one of F1–F5 / M1–M5; lang via `lang_code`.
    local payload
    payload=$(python3 -c "
import json, sys
d = {'input': sys.argv[1], 'voice': sys.argv[3],
     'response_format': 'wav', 'stream': False,
     'total_steps': int(sys.argv[4]), 'speed': float(sys.argv[5])}
if sys.argv[2]:
    d['lang_code'] = sys.argv[2]
print(json.dumps(d))
" "$text" "$lang" "$SUPERTONIC_VOICE" "$SUPERTONIC_STEPS" "$SUPERTONIC_SPEED" 2>/dev/null \
        || printf '{"input":"%s","voice":"%s","response_format":"wav"}' "$text" "$SUPERTONIC_VOICE")

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
    play_wav "$OUTPUT"
    rm -f "$OUTPUT"
}

speak_qwen() {
    local text="$1"
    local lang="$2"

    echo "[tts] Qwen3-TTS voice=${QWEN_TTS_VOICE} lang=${lang} url=${QWEN_TTS_URL}" >&2

    # OpenAI-compatible payload. The model auto-detects language, so `lang`
    # is logged but not sent. WAV avoids the mp3/pydub encode step.
    local payload
    payload=$(python3 -c "
import json, sys
d = {'model': sys.argv[2], 'input': sys.argv[1], 'voice': sys.argv[3],
     'response_format': 'wav', 'speed': float(sys.argv[4])}
print(json.dumps(d))
" "$text" "$QWEN_TTS_MODEL" "$QWEN_TTS_VOICE" "$QWEN_TTS_SPEED" 2>/dev/null \
        || printf '{"model":"%s","input":"%s","voice":"%s","response_format":"wav"}' "$QWEN_TTS_MODEL" "$text" "$QWEN_TTS_VOICE")

    local http_code
    http_code=$(curl -sS -m 60 \
        -o "$OUTPUT" \
        -w '%{http_code}' \
        "${QWEN_TTS_URL}/v1/audio/speech" \
        -H "Content-Type: application/json" \
        -d "$payload") || {
        echo "tts.sh: Qwen3-TTS request failed (curl exit $?)" >&2
        return 1
    }

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "tts.sh: Qwen3-TTS HTTP $http_code" >&2
        rm -f "$OUTPUT"
        return 1
    fi

    [ -f "$OUTPUT" ] && [ -s "$OUTPUT" ] || { echo "tts.sh: Qwen3-TTS produced no audio" >&2; return 1; }
    [ "$TTS_NO_PLAY" = "1" ] && { echo "$OUTPUT"; return 0; }
    play_wav "$OUTPUT"
    rm -f "$OUTPUT"
}

speak_qwen_lazy() {
    local text="$1"
    local lang="$2"
    local _ensure="${QWEN_TTS_LAZY_ENSURE_SH:-$HOME/Qwen3-TTS-Openai-Fastapi/qwen-lazy-ensure.sh}"
    if [ -x "$_ensure" ]; then
        "$_ensure" || echo "[tts] qwen-lazy ensure returned non-zero; trying anyway…" >&2
    else
        echo "[tts] qwen-lazy-ensure.sh not found at $_ensure — server may not start" >&2
    fi
    QWEN_TTS_URL="${QWEN_TTS_URL_LAZY:-http://127.0.0.1:18883}" speak_qwen "$text" "$lang"
}

# Steer one sentence into inworld-tts-2 delivery tags for expressive audio.
# Fail-open: prints the ORIGINAL text on disable / missing script / any error, so
# audio never blocks. Called PER CHUNK (inside the parallel synth jobs) so the LLM
# rewrite of one sentence overlaps the synthesis of the others instead of being one
# serial pre-pass over the whole reply. Steering script lives next to this file.
_inworld_steer_text() {
    local text="$1" lang="$2"
    local steer_sh="${INWORLD_STEER_SH:-$(dirname "${BASH_SOURCE[0]}")/inworld_steer.sh}"
    if [ "${INWORLD_STEER:-auto}" = "0" ] || [ ! -f "$steer_sh" ]; then
        printf '%s' "$text"; return 0
    fi
    local out
    if out=$(INWORLD_API_KEY="${INWORLD_API_KEY:-${INWORLD_TTS_API:-}}" \
            INWORLD_TTS_MODEL="${INWORLD_TTS_MODEL:-inworld-tts-2}" \
            bash "$steer_sh" "$text" "$lang" 2>/dev/null) && [ -n "$out" ]; then
        printf '%s' "$out"
    else
        printf '%s' "$text"
    fi
}

speak_inworld() {
    local text="$1"
    local lang="$2"
    local voice="${INWORLD_TTS_VOICE:-Ashley}"

    if [ -z "${INWORLD_API_KEY:-}" ]; then
        echo "tts.sh: INWORLD_API_KEY not set" >&2
        return 1
    fi

    # Map 2-letter lang code → BCP-47. Inworld accepts a wide set; pass en as en-US.
    local bcp
    case "$lang" in
        es) bcp="es-ES" ;;
        de) bcp="de-DE" ;;
        fr) bcp="fr-FR" ;;
        it) bcp="it-IT" ;;
        pt) bcp="pt-BR" ;;
        ja) bcp="ja-JP" ;;
        ko) bcp="ko-KR" ;;
        zh) bcp="zh-CN" ;;
        ru) bcp="ru-RU" ;;
        ar) bcp="ar-SA" ;;
        hi) bcp="hi-IN" ;;
        nl) bcp="nl-NL" ;;
        pl) bcp="pl-PL" ;;
        en|*) bcp="en-US" ;;
    esac

    echo "[tts] Inworld voice=${voice} model=${INWORLD_TTS_MODEL} lang=${bcp}" >&2

    # Chunk into sentences, request in parallel — same pattern as xAI.
    # TTS_NO_PLAY is handled inside _speak_inworld_chunked (concatenates all
    # chunk WAVs into one file instead of playing sequentially).
    local chunks_json
    chunks_json=$(python3 -c "
import sys, re, json
text = sys.stdin.read().strip()
parts = re.split(r'(?<=[.!?])\s+', text)
merged, buf = [], ''
for p in parts:
    p = p.strip()
    if not p:
        continue
    if buf:
        buf = buf + ' ' + p
    else:
        buf = p
    if len(buf.split()) >= 2:
        merged.append(buf)
        buf = ''
if buf:
    if merged:
        merged[-1] = merged[-1] + ' ' + buf
    else:
        merged.append(buf)
print(json.dumps(merged))
" <<<"$text")

    local count
    count=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$chunks_json")

    if [ "$count" -le 1 ]; then
        local single; single=$(_inworld_steer_text "$text" "$lang")
        _speak_inworld_single "$single" "$bcp" "$voice"
        return $?
    fi

    echo "[tts] Chunking into $count sentences (parallel Inworld)" >&2
    _speak_inworld_chunked "$chunks_json" "$count" "$bcp" "$voice"
}

_speak_inworld_single() {
    local text="$1"
    local bcp="$2"
    local voice="$3"

    local input_json
            input_json=$(python3 -c "
import json, sys
print(json.dumps({
    'text': sys.argv[1],
    'voiceId': sys.argv[2],
    'modelId': sys.argv[3],
    'language': sys.argv[4],
    'audioConfig': {
        'audioEncoding': sys.argv[5],
        'sampleRateHertz': int(sys.argv[6]),
    },
    'deliveryMode': 'BALANCED',
    'applyTextNormalization': 'ON',
}))
" "$text" "$voice" "${INWORLD_TTS_MODEL:-inworld-tts-2}" "$bcp" \
        "${INWORLD_TTS_ENCODING:-LINEAR16}" "${INWORLD_TTS_SAMPLE_RATE:-48000}")

    # Inworld returns JSON: { \"audioContent\": \"<base64-LINEAR16>\" }
    # Decode into a real .wav container so afplay / ffplay can play it.
    local body_json wav_tmp
    wav_tmp=$(mktemp -t inworld.wav)
    body_json=$(mktemp -t inworld.json)
    local http_code
    http_code=$(curl -sS -m 60 \
        -o "$body_json" \
        -w '%{http_code}' \
        "$INWORLD_TTS_URL" \
        -H "Authorization: Basic $INWORLD_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$input_json") || {
        echo "tts.sh: Inworld request failed (curl exit $?)" >&2
        rm -f "$body_json" "$wav_tmp"
        return 1
    }

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "tts.sh: Inworld HTTP $http_code" >&2
        cat "$body_json" >&2
        # 401/403 = auth problem. Mark it so the caller can refuse silent fallback.
        if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
            INWORLD_LAST_AUTH_FAIL=1
            export INWORLD_LAST_AUTH_FAIL
        fi
        rm -f "$body_json" "$wav_tmp"
        return 1
    fi

    # Decode base64 audioContent into WAV (with proper header).
    if ! python3 -c "
import base64, json, struct, sys
with open(sys.argv[1], 'rb') as f:
    body = f.read()
try:
    data = json.loads(body)
except Exception as e:
    print('Inworld: invalid JSON response:', e, file=sys.stderr)
    sys.exit(2)
b64 = data.get('audioContent') or data.get('audio_content') or ''
if not b64:
    print('Inworld: response missing audioContent:', body[:200], file=sys.stderr)
    sys.exit(3)
raw = base64.b64decode(b64)
# Build a minimal RIFF/WAVE header for raw LINEAR16 mono PCM.
sr = int(sys.argv[2])
ch = 1
bps = 16
data_size = len(raw)
with open(sys.argv[3], 'wb') as out:
    out.write(b'RIFF')
    out.write(struct.pack('<I', 36 + data_size))
    out.write(b'WAVE')
    out.write(b'fmt ')
    out.write(struct.pack('<I', 16))             # fmt chunk size
    out.write(struct.pack('<H', 1))              # PCM
    out.write(struct.pack('<H', ch))
    out.write(struct.pack('<I', sr))
    out.write(struct.pack('<I', sr * ch * bps // 8))
    out.write(struct.pack('<H', ch * bps // 8))
    out.write(struct.pack('<H', bps))
    out.write(b'data')
    out.write(struct.pack('<I', data_size))
    out.write(raw)
" "$body_json" "${INWORLD_TTS_SAMPLE_RATE:-48000}" "$wav_tmp"; then
        echo "tts.sh: Inworld audio decode failed" >&2
        rm -f "$body_json" "$wav_tmp"
        return 1
    fi
    rm -f "$body_json"

    [ -f "$wav_tmp" ] && [ -s "$wav_tmp" ] || { echo "tts.sh: Inworld produced no audio" >&2; rm -f "$wav_tmp"; return 1; }
    # Fade edges — Inworld starts on a non-zero sample (onset click).
    fade_wav_edges "$wav_tmp"
    [ "$TTS_NO_PLAY" = "1" ] && {
        echo "$wav_tmp"
        return 0
    }
    play_wav "$wav_tmp"
    rm -f "$wav_tmp"
}

_speak_inworld_chunked() {
    local chunks_json="$1"
    local count="$2"
    local bcp="$3"
    local voice="$4"

    local chunk_dir
    chunk_dir=$(mktemp -d /tmp/opencode-tts-inworld.XXXXXX)

    local i chunk_text wav_prefix
    for ((i=0; i<count; i++)); do
        chunk_text=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])[$i])" "$chunks_json")
        wav_prefix="${chunk_dir}/chunk_$(printf '%03d' $i)"
        (
    # Steer this sentence in its own parallel job so the LLM rewrite overlaps
    # the other chunks' synthesis instead of blocking up front.
    chunk_text=$(_inworld_steer_text "$chunk_text" "$bcp")
    input_json=$(python3 -c "
import json, sys
print(json.dumps({
    'text': sys.argv[1],
    'voiceId': sys.argv[2],
    'modelId': sys.argv[3],
    'language': sys.argv[4],
    'audioConfig': {
        'audioEncoding': sys.argv[5],
        'sampleRateHertz': int(sys.argv[6]),
    },
    'deliveryMode': 'BALANCED',
    'applyTextNormalization': 'ON',
}))
" "$chunk_text" "$voice" "${INWORLD_TTS_MODEL:-inworld-tts-2}" "$bcp" \
                    "${INWORLD_TTS_ENCODING:-LINEAR16}" "${INWORLD_TTS_SAMPLE_RATE:-48000}")

            body_json=$(mktemp)
            chunk_http=$(curl -sS -m 30 -o "$body_json" \
                -w '%{http_code}' \
                "$INWORLD_TTS_URL" \
                -H "Authorization: Basic $INWORLD_API_KEY" \
                -H "Content-Type: application/json" \
                -d "$input_json" 2>/dev/null) || chunk_http=000
            # If the whole batch is failing with 401/403, mark auth fail.
            if [ "$chunk_http" = "401" ] || [ "$chunk_http" = "403" ]; then
                INWORLD_LAST_AUTH_FAIL=1
                export INWORLD_LAST_AUTH_FAIL
            fi
            if [ "$chunk_http" -ge 200 ] && [ "$chunk_http" -lt 300 ]; then
                if python3 -c "
import base64, json, struct, sys
with open(sys.argv[1], 'rb') as f:
    body = f.read()
data = json.loads(body)
b64 = data.get('audioContent') or data.get('audio_content') or ''
if not b64: sys.exit(1)
raw = base64.b64decode(b64)
sr = int(sys.argv[2]); ch = 1; bps = 16
with open(sys.argv[3] + '.wav', 'wb') as out:
    out.write(b'RIFF'); out.write(struct.pack('<I', 36 + len(raw)))
    out.write(b'WAVE'); out.write(b'fmt '); out.write(struct.pack('<I', 16))
    out.write(struct.pack('<H', 1)); out.write(struct.pack('<H', ch))
    out.write(struct.pack('<I', sr)); out.write(struct.pack('<I', sr * ch * bps // 8))
    out.write(struct.pack('<H', ch * bps // 8)); out.write(struct.pack('<H', bps))
    out.write(b'data'); out.write(struct.pack('<I', len(raw))); out.write(raw)
" "$body_json" "${INWORLD_TTS_SAMPLE_RATE:-48000}" "$wav_prefix" 2>/dev/null; then
                    # Fade each chunk's own edges — Inworld clips start on a
                    # non-zero sample, so every chunk boundary pops without this.
                    fade_wav_edges "${wav_prefix}.wav"
                    touch "${wav_prefix}.ready"
                else
                    touch "${wav_prefix}.failed"
                fi
            else
                touch "${wav_prefix}.failed"
            fi
            rm -f "$body_json"
        ) &
    done

    if [ "${TTS_NO_PLAY:-0}" = "1" ]; then
        # Barge-in mode needs the whole utterance as one WAV — wait for every
        # chunk to finish, then concatenate below.
        local ready_count=0
        while [ "$ready_count" -lt "$count" ]; do
            ready_count=0
            local j
            for ((j=0; j<count; j++)); do
                wav_prefix="${chunk_dir}/chunk_$(printf '%03d' $j)"
                if [ -f "${wav_prefix}.ready" ] || [ -f "${wav_prefix}.failed" ]; then
                    ready_count=$((ready_count + 1))
                fi
            done
            [ "$ready_count" -lt "$count" ] && sleep 0.05
        done

        local output_wav
        output_wav=$(mktemp -t inworld-chunked.wav)
        python3 -c "
import wave, sys, os, struct
output = sys.argv[1]
chunk_dir = sys.argv[2]
count = int(sys.argv[3])
frames_list = []
params = None
for i in range(count):
    path = f'{chunk_dir}/chunk_{i:03d}.wav'
    if not os.path.exists(path):
        continue
    with wave.open(path, 'rb') as w:
        if params is None:
            params = w.getparams()
        frames_list.append(w.readframes(w.getnframes()))
if params is None:
    sys.exit(1)
with wave.open(output, 'wb') as out:
    out.setparams(params)
    out.writeframes(b''.join(frames_list))
# 5ms fade-in/out — Inworld starts on a non-zero sample
with wave.open(output, 'rb') as w:
    params = w.getparams()
    frames = w.readframes(w.getnframes())
n = len(frames) // params.sampwidth
fmt = {1:'b', 2:'h', 4:'i'}[params.sampwidth]
samples = list(struct.unpack(f'<{n}{fmt}', frames))
fade_n = int(params.framerate * 0.005)
if fade_n > 0 and n > fade_n * 2:
    for i in range(fade_n):
        samples[i] = int(samples[i] * (i / fade_n))
        samples[-(i+1)] = int(samples[-(i+1)] * (i / fade_n))
with wave.open(output, 'wb') as w:
    w.setparams(params)
    w.writeframes(struct.pack(f'<{n}{fmt}', *samples))
" "$output_wav" "$chunk_dir" "$count" 2>/dev/null && {
            rm -rf "$chunk_dir"
            echo "$output_wav"
            return 0
        }
        rm -rf "$chunk_dir"
        return 1
    fi

    # Stream: play each chunk in order the instant it is ready, while later chunks
    # are still being synthesized in parallel. First audio starts after chunk 0
    # returns instead of after the whole reply finishes.
    for ((i=0; i<count; i++)); do
        wav_prefix="${chunk_dir}/chunk_$(printf '%03d' $i)"
        while [ ! -f "${wav_prefix}.ready" ] && [ ! -f "${wav_prefix}.failed" ]; do
            sleep 0.05
        done
        [ -f "${wav_prefix}.ready" ] && play_wav "${wav_prefix}.wav"
    done

    rm -rf "$chunk_dir"
    return 0
}

# --- Generic OpenAI-compatible remote TTS (for slow CPUs) --------------------
# Hits <OPENAI_TTS_URL>/audio/speech with the OpenAI speech schema. Streams by
# sentence like xAI/Inworld: requests fire in parallel, playback starts on the
# first sentence. Works with OpenAI and any OpenAI-compatible server.
speak_openai() {
    local text="$1" lang="$2"

    if [ -z "${OPENAI_TTS_KEY:-}" ]; then
        echo "tts.sh: OPENAI_TTS_KEY (or OPENAI_API_KEY) not set" >&2
        return 1
    fi
    echo "[tts] OpenAI-compatible model=${OPENAI_TTS_MODEL} voice=${OPENAI_TTS_VOICE} url=${OPENAI_TTS_URL} lang=${lang}" >&2

    if [ "${TTS_NO_PLAY:-0}" = "1" ]; then
        _speak_openai_single "$text"
        return $?
    fi

    # Split into sentence chunks on . ! ? (same merge rule as the other engines).
    local chunks_json
    chunks_json=$(python3 -c "
import sys, re, json
text = sys.stdin.read().strip()
parts = re.split(r'(?<=[.!?])\s+', text)
merged, buf = [], ''
for p in parts:
    p = p.strip()
    if not p:
        continue
    buf = (buf + ' ' + p) if buf else p
    if len(buf.split()) >= 2:
        merged.append(buf); buf = ''
if buf:
    if merged: merged[-1] = merged[-1] + ' ' + buf
    else: merged.append(buf)
print(json.dumps(merged))
" <<<"$text")
    local count
    count=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$chunks_json")
    if [ "$count" -le 1 ]; then
        _speak_openai_single "$text"
        return $?
    fi
    echo "[tts] Chunking into $count sentences (parallel OpenAI-compatible)" >&2
    _speak_openai_chunked "$chunks_json" "$count"
}

_openai_payload() {
    python3 -c "
import json, sys
print(json.dumps({'model': sys.argv[2], 'input': sys.argv[1],
                  'voice': sys.argv[3], 'response_format': sys.argv[4]}))
" "$1" "$OPENAI_TTS_MODEL" "$OPENAI_TTS_VOICE" "$OPENAI_TTS_FORMAT"
}

_speak_openai_single() {
    local text="$1" payload http_code
    payload=$(_openai_payload "$text")
    http_code=$(curl -sS -m 60 -o "$OUTPUT" -w '%{http_code}' \
        "${OPENAI_TTS_URL%/}/audio/speech" \
        -H "Authorization: Bearer $OPENAI_TTS_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload") || { echo "tts.sh: OpenAI TTS request failed (curl exit $?)" >&2; return 1; }
    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "tts.sh: OpenAI TTS HTTP $http_code" >&2; rm -f "$OUTPUT"; return 1
    fi
    [ -f "$OUTPUT" ] && [ -s "$OUTPUT" ] || { echo "tts.sh: OpenAI TTS produced no audio" >&2; return 1; }
    [ "$TTS_NO_PLAY" = "1" ] && { echo "$OUTPUT"; return 0; }
    play_wav "$OUTPUT"
    rm -f "$OUTPUT"
}

_speak_openai_chunked() {
    local chunks_json="$1" count="$2"
    local chunk_dir; chunk_dir=$(mktemp -d /tmp/opencode-tts-openai.XXXXXX)

    local i chunk_text wav_prefix
    for ((i=0; i<count; i++)); do
        chunk_text=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])[$i])" "$chunks_json")
        wav_prefix="${chunk_dir}/chunk_$(printf '%03d' $i)"
        (
            payload=$(_openai_payload "$chunk_text")
            if curl -sS -m 30 -o "${wav_prefix}.wav" \
                "${OPENAI_TTS_URL%/}/audio/speech" \
                -H "Authorization: Bearer $OPENAI_TTS_KEY" \
                -H "Content-Type: application/json" \
                -d "$payload" 2>/dev/null && [ -s "${wav_prefix}.wav" ]; then
                touch "${wav_prefix}.ready"
            else
                echo "[tts] OpenAI chunk $i failed" >&2
                touch "${wav_prefix}.failed"
            fi
        ) &
    done

    for ((i=0; i<count; i++)); do
        wav_prefix="${chunk_dir}/chunk_$(printf '%03d' $i)"
        while [ ! -f "${wav_prefix}.ready" ] && [ ! -f "${wav_prefix}.failed" ]; do
            sleep 0.05
        done
        [ -f "${wav_prefix}.ready" ] && play_wav "${wav_prefix}.wav"
    done
    rm -rf "$chunk_dir"
    return 0
}

# --- Fallback policy ---------------------------------------------------------
# Always exhaust the LOCAL engines before the xAI cloud. The selected engine
# runs first, then the remaining local engine(s); xAI is the final resort, used
# only if every local engine fails. Selecting TTS_ENGINE=xai explicitly honors
# that choice first, then still falls back to the local engines.
engine="$(printf '%s' "${TTS_ENGINE}" | tr '[:upper:]' '[:lower:]')"
case "$engine" in
    qwen|qwen3|qwen3-tts|qwen-tts)
        if speak_qwen "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Qwen3-TTS failed → trying Supertonic (local)…" >&2
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic failed → trying NeuTTS (local)…" >&2
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] NeuTTS failed → xAI cloud (last resort)…" >&2
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    supertonic|coreml-tts)
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic failed → trying NeuTTS (local)…" >&2
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] NeuTTS failed → xAI cloud (last resort)…" >&2
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    neutts|neuphonic)
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] NeuTTS failed → trying Inflect-Nano (local, English)…" >&2
        if speak_inflect "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Inflect-Nano failed → trying Supertonic (local)…" >&2
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic failed → xAI cloud (last resort)…" >&2
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    inflect|inflect-nano)
        if speak_inflect "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Inflect-Nano failed → trying NeuTTS (local)…" >&2
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] NeuTTS failed → trying Supertonic (local)…" >&2
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic failed → xAI cloud (last resort)…" >&2
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    xai)
        # Explicit cloud selection: honored first, then local fallbacks.
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] xAI failed → trying Supertonic (local)…" >&2
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic failed → trying NeuTTS (local)…" >&2
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    inworld)
        # Explicit cloud selection: honored first, then local fallbacks.
        if speak_inworld "$TEXT" "$LANG"; then exit 0; fi
        # If Inworld failed for a credential reason (401/403), do NOT fall back to
        # local engines silently — the user explicitly asked for Inworld and a
        # bad key needs to be fixed, not papered over. Surface the error loudly.
        if [ "${INWORLD_LAST_AUTH_FAIL:-0}" = "1" ]; then
            echo "" >&2
            echo "tts.sh: Inworld rejected the API key (HTTP 401/403)." >&2
            echo "       Refusing to silently fall back to local engines." >&2
            echo "       Fix: regenerate a 'Basic (Base64)' key at" >&2
            echo "         https://platform.inworld.ai/api-keys" >&2
            echo "       Then update INWORLD_TTS_API in ~/.zshrc (or run" >&2
            echo "         'inworld auth login && inworld auth print-api-key > ~/.inworld_api_key')." >&2
            exit 3
        fi
        echo "[tts] Inworld failed (non-auth) → trying Qwen3-TTS (local)…" >&2
        if speak_qwen "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Qwen3-TTS failed → trying Supertonic (local)…" >&2
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic failed → trying NeuTTS (local)…" >&2
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    openai|openai-tts)
        # Remote OpenAI-compatible (slow-CPU offload): honored first, then the
        # local engines (Supertonic is the repo default, so it leads the fallback).
        if speak_openai "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] OpenAI-compatible failed → trying Supertonic (local)…" >&2
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic failed → trying NeuTTS (local)…" >&2
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    qwen-lazy|lazy)
        if speak_qwen_lazy "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] qwen-lazy failed → trying Supertonic (local)…" >&2
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic failed → trying NeuTTS (local)…" >&2
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] NeuTTS failed → xAI cloud (last resort)…" >&2
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    *)
        echo "tts.sh: unknown TTS_ENGINE=${TTS_ENGINE}. Use: supertonic, qwen, qwen-lazy, neutts, inflect, openai, inworld, xai." >&2
        exit 2
        ;;
esac
