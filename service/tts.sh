#!/bin/bash
# tts.sh — Multi-engine TTS CLI for OpenCode / talk skill.
#
# Local (CPU, default):  supertonic → neutts        (also: supertonic2 opt-in)
# Remote (for slow CPUs): openai  — any OpenAI-compatible /v1/audio/speech endpoint
#                         inworld — expressive cloud TTS (per-sentence steering)
#                         xai     — xAI cloud (last-resort fallback)
#
# Set TTS_ENGINE to override (default: supertonic). For a LOCAL primary engine,
# the LOCAL engines are always exhausted before any cloud engine — cloud is only
# used if every local engine fails. Choosing a remote engine explicitly
# (openai/inworld/xai) honors that choice first, then still falls back to local.
# macOS `say` is intentionally not available.
#
# Why a remote OpenAI-compatible option? The local ONNX engines are tuned for CPU,
# but on a slow/old CPU even 8-step Supertonic can lag a live conversation. Point
# TTS_ENGINE=openai at any OpenAI-compatible speech endpoint (OpenAI, a hosted
# provider, or your own remote GPU box running an OpenAI-compatible server) to
# offload synthesis entirely. See docs/providers.md.

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

# Apply a short fade-in/out to a WAV in place to kill onset/offset clicks. Some
# neural TTS (notably Inworld) starts a clip on a non-zero sample — an audible pop
# at the start of every chunk. A few ms of fade ramps that to zero. Idempotent and
# cheap; safe on any mono/stereo 8/16/32-bit PCM WAV. No-op when TTS_FADE_MS=0.
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

# Split text into sentence-ish chunks on . ! ? and print a JSON array. Short
# fragments are merged so a stray "Sí." doesn't become its own request. Shared by
# the chunked/streaming engines (openai, inworld) so the first sentence can play
# while later ones are still being synthesized.
_chunk_sentences() {
    python3 -c "
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
        merged.append(buf)
        buf = ''
if buf:
    if merged:
        merged[-1] = merged[-1] + ' ' + buf
    else:
        merged.append(buf)
print(json.dumps(merged))
"
}

# --- Engine config -----------------------------------------------------------
: "${TTS_ENGINE:=supertonic}"
: "${XAI_API_KEY:=${XAI_API_KEY:-}}"
: "${XAI_TTS_VOICE:=eve}"
: "${XAI_TTS_MODEL:=grok-2-audio}"
: "${SUPERTONIC_URL:=http://127.0.0.1:8766}"
: "${SUPERTONIC_SH:=$HOME/.config/opencode/skills/supertonic-tts/supertonic.sh}"
: "${SUPERTONIC_VOICE:=F4}"   # Supertonic 3 voices: F1–F5 / M1–M5 (default F4)
# Quality presets: normal = 8 steps (fast), high = 20 steps (best). Set
# TTS_QUALITY=high for HQ, or override SUPERTONIC_STEPS=<1-20> directly (wins).
: "${TTS_QUALITY:=normal}"
case "$(printf '%s' "${TTS_QUALITY}" | tr '[:upper:]' '[:lower:]')" in
    high|hq|best) _q_steps=20 ;;
    *)            _q_steps=8  ;;
esac
: "${SUPERTONIC_STEPS:=$_q_steps}"   # denoising steps (1–20)
: "${SUPERTONIC_SPEED:=1.05}"
# Supertonic 2 (optional) — Supertonic Express 2, onnx-community/Supertonic-TTS-2-ONNX.
# Same OpenAI-compatible /v1/audio/speech API as Supertonic 3, served on :8880.
# Not auto-installed; opt in with: bash integrations/supertonic2/install.sh
: "${SUPERTONIC2_URL:=http://127.0.0.1:8880}"
: "${SUPERTONIC2_VOICE:=M1}"          # Supertonic 2 voices: F1–F5 / M1–M5 (default M1)
: "${SUPERTONIC2_STEPS:=$_q_steps}"   # denoising steps (1–20), shares TTS_QUALITY preset
: "${SUPERTONIC2_SPEED:=1.05}"
: "${NEUTTS_URL:=http://127.0.0.1:8020}"
: "${NEUTTS_MODEL:=neuphonic/neutts-nano-q8-gguf}"
: "${NEUTTS_MODEL_ES:=neuphonic/neutts-nano-spanish-q8-gguf}"
: "${NEUTTS_MODEL_DE:=neuphonic/neutts-nano-german-q8-gguf}"
: "${NEUTTS_MODEL_FR:=neuphonic/neutts-nano-french-q8-gguf}"
# Generic OpenAI-compatible remote TTS (for slow CPUs / no local backend). Works
# with OpenAI's own /v1/audio/speech, a hosted provider, or your own remote box
# running any OpenAI-compatible speech server. WAV is requested so playback needs
# no transcode. Defaults target OpenAI; override OPENAI_TTS_URL for other providers.
: "${OPENAI_TTS_URL:=https://api.openai.com/v1}"
: "${OPENAI_TTS_KEY:=${OPENAI_API_KEY:-}}"
: "${OPENAI_TTS_MODEL:=gpt-4o-mini-tts}"
: "${OPENAI_TTS_VOICE:=alloy}"
: "${OPENAI_TTS_FORMAT:=wav}"
# Inworld TTS (cloud, Basic auth). Expressive: a steering pre-processor adds
# per-sentence delivery tags (inworld_steer.sh). Model: inworld-tts-2 / -2-max.
# Requires INWORLD_API_KEY (Basic/base64 key — https://platform.inworld.ai/api-keys).
: "${INWORLD_TTS_VOICE:=Ashley}"
: "${INWORLD_TTS_MODEL:=inworld-tts-2}"
: "${INWORLD_TTS_URL:=https://api.inworld.ai/tts/v1/voice}"
: "${INWORLD_TTS_ENCODING:=LINEAR16}"   # Inworld returns LINEAR16 (48 kHz mono) by default
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

# Supertonic Express 2 and 3 share the same OpenAI-compatible /v1/audio/speech
# endpoint: required field is `input`; voice is one of F1–F5 / M1–M5; lang via
# `lang_code`. This helper drives either server.
#   args: label url voice steps speed text lang
_speak_supertonic_endpoint() {
    local label="$1" url="$2" voice="$3" steps="$4" speed="$5" text="$6" lang="$7"

    echo "[tts] ${label} voice=${voice} steps=${steps} (${TTS_QUALITY}) lang=${lang} url=${url}" >&2

    local payload
    payload=$(python3 -c "
import json, sys
d = {'input': sys.argv[1], 'voice': sys.argv[3],
     'response_format': 'wav', 'stream': False,
     'total_steps': int(sys.argv[4]), 'speed': float(sys.argv[5])}
if sys.argv[2]:
    d['lang_code'] = sys.argv[2]
print(json.dumps(d))
" "$text" "$lang" "$voice" "$steps" "$speed" 2>/dev/null \
        || printf '{"input":"%s","voice":"%s","response_format":"wav"}' "$text" "$voice")

    local http_code
    http_code=$(curl -sS -m 60 \
        -o "$OUTPUT" \
        -w '%{http_code}' \
        "${url}/v1/audio/speech" \
        -H "Content-Type: application/json" \
        -d "$payload") || {
        echo "tts.sh: ${label} request failed (curl exit $?)" >&2
        return 1
    }

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "tts.sh: ${label} HTTP $http_code" >&2
        rm -f "$OUTPUT"
        return 1
    fi

    [ -f "$OUTPUT" ] && [ -s "$OUTPUT" ] || { echo "tts.sh: ${label} produced no audio" >&2; return 1; }
    [ "$TTS_NO_PLAY" = "1" ] && { echo "$OUTPUT"; return 0; }
    play_wav "$OUTPUT"
    rm -f "$OUTPUT"
}

speak_supertonic() {
    _speak_supertonic_endpoint "Supertonic" "$SUPERTONIC_URL" "$SUPERTONIC_VOICE" \
        "$SUPERTONIC_STEPS" "$SUPERTONIC_SPEED" "$1" "$2"
}

# Supertonic 2 (Supertonic Express 2) — optional local engine on :8880.
speak_supertonic2() {
    _speak_supertonic_endpoint "Supertonic2" "$SUPERTONIC2_URL" "$SUPERTONIC2_VOICE" \
        "$SUPERTONIC2_STEPS" "$SUPERTONIC2_SPEED" "$1" "$2"
}

# --- Generic OpenAI-compatible remote TTS (for slow CPUs) --------------------
# Hits <OPENAI_TTS_URL>/audio/speech with the OpenAI speech schema. Streams by
# sentence like xAI: requests fire in parallel, playback starts on the first
# sentence. Works with OpenAI and any OpenAI-compatible server (vLLM, hosted
# providers, your own remote GPU box).
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

    local chunks_json count
    chunks_json=$(_chunk_sentences <<<"$text")
    count=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$chunks_json")
    if [ "$count" -le 1 ]; then
        _speak_openai_single "$text"
        return $?
    fi
    echo "[tts] Chunking into $count sentences (parallel OpenAI-compatible)" >&2
    _speak_openai_chunked "$chunks_json" "$count"
}

# Build the OpenAI speech request JSON for one piece of text.
_openai_payload() {
    python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[2],
    'input': sys.argv[1],
    'voice': sys.argv[3],
    'response_format': sys.argv[4],
}))
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

    # Stream: play each chunk in order the instant it is ready.
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

# --- Inworld expressive cloud TTS -------------------------------------------
# Steer one sentence into inworld-tts-2 delivery tags. Fail-open: prints the
# ORIGINAL text on disable / missing script / any error, so audio never blocks.
# Called PER CHUNK (inside the parallel synth jobs) so the LLM rewrite of one
# sentence overlaps the synthesis of the others instead of being one serial
# ~2s pre-pass over the whole reply.
_inworld_steer_text() {
    local text="$1" lang="$2"
    # Steering script lives next to this file; INWORLD_STEER_SH overrides.
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
    local text="$1" lang="$2"
    local voice="${INWORLD_TTS_VOICE:-Ashley}"

    if [ -z "${INWORLD_API_KEY:-}" ]; then
        echo "tts.sh: INWORLD_API_KEY not set" >&2
        return 1
    fi

    # Map 2-letter lang → BCP-47 (Inworld wants the full tag).
    local bcp
    case "$lang" in
        es) bcp="es-ES" ;; de) bcp="de-DE" ;; fr) bcp="fr-FR" ;; it) bcp="it-IT" ;;
        pt) bcp="pt-BR" ;; ja) bcp="ja-JP" ;; ko) bcp="ko-KR" ;; zh) bcp="zh-CN" ;;
        ru) bcp="ru-RU" ;; ar) bcp="ar-SA" ;; hi) bcp="hi-IN" ;; nl) bcp="nl-NL" ;;
        pl) bcp="pl-PL" ;; en|*) bcp="en-US" ;;
    esac
    echo "[tts] Inworld voice=${voice} model=${INWORLD_TTS_MODEL} lang=${bcp}" >&2

    # Barge-in (TTS_NO_PLAY) needs the whole reply as ONE WAV file path on stdout,
    # not streamed playback — use the single-request path (steer the full text).
    if [ "${TTS_NO_PLAY:-0}" = "1" ]; then
        local whole; whole=$(_inworld_steer_text "$text" "$lang")
        _speak_inworld_single "$whole" "$bcp" "$voice"
        return $?
    fi

    # Steering is applied PER CHUNK inside the parallel synth jobs (and in the
    # single-chunk path) — each chunk is a sentence, exactly the granularity the
    # steering prompt tags at. Chunk on the RAW text here.
    local chunks_json count
    chunks_json=$(_chunk_sentences <<<"$text")
    count=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$chunks_json")
    if [ "$count" -le 1 ]; then
        local single; single=$(_inworld_steer_text "$text" "$lang")
        _speak_inworld_single "$single" "$bcp" "$voice"
        return $?
    fi
    echo "[tts] Chunking into $count sentences (parallel Inworld)" >&2
    _speak_inworld_chunked "$chunks_json" "$count" "$bcp" "$voice"
}

# Build the Inworld request JSON for one piece of text.
_inworld_payload() {
    python3 -c "
import json, sys
print(json.dumps({
    'text': sys.argv[1],
    'voiceId': sys.argv[2],
    'modelId': sys.argv[3],
    'language': sys.argv[4],
    'audioConfig': {'audioEncoding': sys.argv[5], 'sampleRateHertz': int(sys.argv[6])},
    'deliveryMode': 'BALANCED',
    'applyTextNormalization': 'ON',
}))
" "$1" "$2" "${INWORLD_TTS_MODEL:-inworld-tts-2}" "$3" \
    "${INWORLD_TTS_ENCODING:-LINEAR16}" "${INWORLD_TTS_SAMPLE_RATE:-48000}"
}

# Decode Inworld's base64 audioContent (raw LINEAR16 PCM) into a real WAV file.
_inworld_decode() {
    local body_json="$1" out_wav="$2"
    python3 -c "
import base64, json, struct, sys
with open(sys.argv[1], 'rb') as f:
    data = json.loads(f.read())
b64 = data.get('audioContent') or data.get('audio_content') or ''
if not b64:
    sys.exit(1)
raw = base64.b64decode(b64)
sr = int(sys.argv[2]); ch = 1; bps = 16
with open(sys.argv[3], 'wb') as out:
    out.write(b'RIFF'); out.write(struct.pack('<I', 36 + len(raw)))
    out.write(b'WAVE'); out.write(b'fmt '); out.write(struct.pack('<I', 16))
    out.write(struct.pack('<H', 1)); out.write(struct.pack('<H', ch))
    out.write(struct.pack('<I', sr)); out.write(struct.pack('<I', sr * ch * bps // 8))
    out.write(struct.pack('<H', ch * bps // 8)); out.write(struct.pack('<H', bps))
    out.write(b'data'); out.write(struct.pack('<I', len(raw))); out.write(raw)
" "$body_json" "${INWORLD_TTS_SAMPLE_RATE:-48000}" "$out_wav"
}

_speak_inworld_single() {
    local text="$1" bcp="$2" voice="$3"
    local payload body_json wav_tmp http_code
    payload=$(_inworld_payload "$text" "$voice" "$bcp")
    body_json=$(mktemp); wav_tmp=$(mktemp -t inworld.wav)
    http_code=$(curl -sS -m 60 -o "$body_json" -w '%{http_code}' \
        "$INWORLD_TTS_URL" \
        -H "Authorization: Basic $INWORLD_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload") || { echo "tts.sh: Inworld request failed (curl exit $?)" >&2; rm -f "$body_json" "$wav_tmp"; return 1; }
    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "tts.sh: Inworld HTTP $http_code" >&2; sed -n '1,4p' "$body_json" >&2
        [ "$http_code" = "401" ] || [ "$http_code" = "403" ] && { INWORLD_LAST_AUTH_FAIL=1; export INWORLD_LAST_AUTH_FAIL; }
        rm -f "$body_json" "$wav_tmp"; return 1
    fi
    if ! _inworld_decode "$body_json" "$wav_tmp"; then
        echo "tts.sh: Inworld audio decode failed" >&2; rm -f "$body_json" "$wav_tmp"; return 1
    fi
    rm -f "$body_json"
    [ -s "$wav_tmp" ] || { echo "tts.sh: Inworld produced no audio" >&2; rm -f "$wav_tmp"; return 1; }
    fade_wav_edges "$wav_tmp"
    [ "$TTS_NO_PLAY" = "1" ] && { echo "$wav_tmp"; return 0; }
    play_wav "$wav_tmp"
    rm -f "$wav_tmp"
}

_speak_inworld_chunked() {
    local chunks_json="$1" count="$2" bcp="$3" voice="$4"
    local chunk_dir; chunk_dir=$(mktemp -d /tmp/opencode-tts-inworld.XXXXXX)

    local i chunk_text wav_prefix
    for ((i=0; i<count; i++)); do
        chunk_text=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])[$i])" "$chunks_json")
        wav_prefix="${chunk_dir}/chunk_$(printf '%03d' $i)"
        (
            # Steer this sentence in its own parallel job so the LLM rewrite
            # overlaps the other chunks' synthesis instead of blocking up front.
            chunk_text=$(_inworld_steer_text "$chunk_text" "$bcp")
            payload=$(_inworld_payload "$chunk_text" "$voice" "$bcp")
            body_json=$(mktemp)
            chunk_http=$(curl -sS -m 30 -o "$body_json" -w '%{http_code}' \
                "$INWORLD_TTS_URL" \
                -H "Authorization: Basic $INWORLD_API_KEY" \
                -H "Content-Type: application/json" \
                -d "$payload" 2>/dev/null) || chunk_http=000
            if [ "$chunk_http" = "401" ] || [ "$chunk_http" = "403" ]; then
                INWORLD_LAST_AUTH_FAIL=1; export INWORLD_LAST_AUTH_FAIL
            fi
            if [ "$chunk_http" -ge 200 ] && [ "$chunk_http" -lt 300 ] \
                && _inworld_decode "$body_json" "${wav_prefix}.wav" 2>/dev/null; then
                fade_wav_edges "${wav_prefix}.wav"
                touch "${wav_prefix}.ready"
            else
                touch "${wav_prefix}.failed"
            fi
            rm -f "$body_json"
        ) &
    done

    # Stream: play each chunk in order the instant it is ready.
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
    supertonic|coreml-tts)
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic failed → trying NeuTTS (local)…" >&2
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] NeuTTS failed → xAI cloud (last resort)…" >&2
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    supertonic2|supertonic-2)
        if speak_supertonic2 "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic2 failed → trying Supertonic (local)…" >&2
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
    openai|openai-tts)
        # Remote OpenAI-compatible (slow-CPU offload): honored first, then local.
        if speak_openai "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] OpenAI-compatible failed → trying Supertonic (local)…" >&2
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic failed → trying NeuTTS (local)…" >&2
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    inworld)
        # Expressive cloud: honored first, then local fallbacks.
        if speak_inworld "$TEXT" "$LANG"; then exit 0; fi
        # A bad/forbidden key is a config error the user must fix — do NOT silently
        # fall back to a different voice when they explicitly asked for Inworld.
        if [ "${INWORLD_LAST_AUTH_FAIL:-0}" = "1" ]; then
            echo "" >&2
            echo "tts.sh: Inworld rejected the API key (HTTP 401/403)." >&2
            echo "       Refusing to silently fall back to local engines." >&2
            echo "       Fix: regenerate a 'Basic (Base64)' key at" >&2
            echo "         https://platform.inworld.ai/api-keys" >&2
            echo "       and set INWORLD_API_KEY (or INWORLD_TTS_API)." >&2
            exit 3
        fi
        echo "[tts] Inworld failed (non-auth) → trying Supertonic (local)…" >&2
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic failed → trying NeuTTS (local)…" >&2
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] NeuTTS failed → xAI cloud (last resort)…" >&2
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    *)
        echo "tts.sh: unknown TTS_ENGINE=${TTS_ENGINE}. Use: supertonic, supertonic2, neutts, openai, inworld, xai." >&2
        exit 2
        ;;
esac
