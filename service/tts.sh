#!/bin/bash
# tts.sh — TTS CLI for OpenCode / talk skill.
#
# Default engine: xai (voice iris). Local engines (qwen3-mlx, chatterbox,
# supertonic, qwen, neutts, inflect, vibevoice) are NOT used by default — they
# were removed from the default path because they do not work on this setup.
# Set TTS_ENGINE explicitly to use any other engine. macOS `say` is never used.
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

# Split text into sentence chunks on . ! ? — merges any fragment shorter than
# 2 words into a neighbor so we never end up synthesizing a lone "Mr." or "3.".
# Shared by every engine that chunks (xAI, OpenAI, Chatterbox Turbo MLX).
split_sentences_json() {
    python3 -c "
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
" <<<"$1"
}

# Like split_sentences_json but also enforces a maximum of 5 words per chunk
# so Chatterbox Turbo MLX stays in its 2% WER sweet spot. Splits on punctuation
# first, then sub-chunks any >5-word segments at word boundaries. Short chunks
# (1-2 words) are merged with neighbours to avoid abrupt single-word utterances.
split_sentences_5w_json() {
    python3 -c "
import sys, re, json
text = sys.stdin.read().strip()
if not text:
    print('[]')
    sys.exit(0)
parts = re.split(r'(?<=[.!?])\s+', text)
chunks = []
for p in parts:
    p = p.strip()
    if not p:
        continue
    words = p.split()
    for i in range(0, len(words), 5):
        chunk = ' '.join(words[i:i+5])
        if chunk.rstrip() and not chunk.rstrip().endswith(('.', '!', '?')):
            chunk += '.'
        chunks.append(chunk)
# merge short tails (1-2 words) into previous chunk — accept the
# occasional 6-8 word result from a natural merge rather than
# re-splitting and creating orphan fragments.
merged = []
for c in chunks:
    c = c.strip()
    if not c:
        continue
    if len(c.rstrip('.!?').split()) < 3 and merged:
        merged[-1] = merged[-1].rstrip('.!?') + ' ' + c
    else:
        merged.append(c)
print(json.dumps(merged))
" <<<"$1"
}

# Split for Qwen3-TTS at sentence boundaries while keeping every request small
# enough to avoid the model dropping a late clause. Whole sentences are packed
# together up to max_words; only a single overlong sentence is split by words.
# The configured limit is clamped to 20-30 words (default 25).
split_sentences_max_words_json() {
    local text="$1"
    local requested_max="${2:-25}"
    python3 -c '
import json, re, sys

text = re.sub(r"\s+", " ", sys.argv[1]).strip()
try:
    max_words = int(sys.argv[2])
except (TypeError, ValueError):
    max_words = 25
max_words = max(20, min(30, max_words))

sentences = [
    part.strip()
    for part in re.split(r"(?<=[.!?])\s+", text)
    if part.strip()
]
chunks = []
current = []

def flush():
    if current:
        chunks.append(" ".join(current))
        current.clear()

for sentence in sentences:
    words = sentence.split()
    if len(words) > max_words:
        flush()
        while len(words) > max_words:
            chunks.append(" ".join(words[:max_words]))
            words = words[max_words:]
        current.extend(words)
        continue
    if current and len(current) + len(words) > max_words:
        flush()
    current.extend(words)

flush()
print(json.dumps(chunks, ensure_ascii=False))
' "$text" "$requested_max"
}

# Apply a short fade-in/out to a WAV in place to kill onset/offset clicks.
# Some neural TTS clips start on a non-zero sample — the first
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
# Default engine is xAI cloud TTS (needs XAI_API_KEY), voice "iris" by default.
# Local engines were removed from the default path — they don't work here —
# but remain selectable with TTS_ENGINE=<name>:
#   chatterbox-turbo-mlx — local Lucía Chatterbox Turbo bundle (Apple Silicon)
#   qwen      — local MLX Qwen3-TTS server (Apple Silicon). Setup/server:
#               https://github.com/groxaxo/Qwen3-TTS-Openai-Fastapi
#   neutts    — local NeuTTS GGUF server
: "${TTS_ENGINE:=xai}"
: "${CHATTERBOX_TURBO_MLX_PYTHON:=$HOME/.venvs/chatterbox-turbo-mlx/bin/python}"
: "${CHATTERBOX_TURBO_MLX_MODEL:=$HOME/mlx-models/chatterbox-lucia-latam-ordered-turbo-mlx-8bit-g128}"
: "${CHATTERBOX_TURBO_MLX_REF_AUDIO:=$HOME/chatterbox-finetunino/latam_runs/profiles/lucia-latam-ar-recipe-ordered/reference.wav}"
# For English text, use the original unquantized base checkpoint (this is the
# exact base repo the Lucía voice was fine-tuned/quantized from) with its own
# built-in conditioning instead of Lucía's Spanish-accented voice — no ref-audio
# override, so it falls back to the model's baked-in conds.safetensors.
: "${CHATTERBOX_TURBO_MLX_MODEL_EN:=$HOME/.cache/huggingface/hub/models--mlx-community--chatterbox-turbo-fp16/snapshots/b2d0a13aa7cfff0a06d9acb247ae91c8f19a6d75}"
: "${CHATTERBOX_TURBO_MLX_REF_AUDIO_EN:=}"
: "${CHATTERBOX_TURBO_MLX_TEMPERATURE:=0.75}"
: "${CHATTERBOX_TURBO_MLX_TOP_P:=0.95}"
: "${CHATTERBOX_TURBO_MLX_TOP_K:=1000}"
: "${CHATTERBOX_TURBO_MLX_REPETITION_PENALTY:=1.2}"
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
: "${XAI_TTS_VOICE:=iris}"
: "${GEMINI_TTS_MODEL:=gemini-3.1-flash-tts-preview}"
: "${GEMINI_TTS_VOICE:=Kore}"
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

# shellcheck source=tts_lang.sh
. "${TTS_LANG_SH:=$HOME/.config/opencode/tts_lang.sh}"

TEXT="${1:-Hello.}"
OUTPUT="${TTS_OUTPUT:-/tmp/opencode-speech.wav}"
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


# --- xAI speech-direction tagging --------------------------------------------
# Every sentence sent to xAI TTS is first tagged by groxaxo/xai-sentence-tagger
# so the voice carries emotion. Fails open: untagged text on any error.
XAI_TAG_SH="${XAI_TAG_SH:-$HOME/.local/bin/xai_tag.sh}"

_xai_tag() {
    local t="$1"
    if [ "${XAI_TAG:-1}" != "1" ] || [ ! -x "$XAI_TAG_SH" ]; then
        printf '%s' "$t"; return 0
    fi
    "$XAI_TAG_SH" "$t" 2>/dev/null || printf '%s' "$t"
}
# --- end xAI speech-direction tagging ----------------------------------------


# --- Google Gemini TTS (30 prebuilt voices) -----------------------------------
# Provider contract: docs/GOOGLE_TTS_REFERENCE.md in groxaxo/xAI-Voice-Studio.
# Direction is English square-bracket instruction, e.g. "[warmly]Hola.".
# Voices: Zephyr Puck Charon Kore Fenrir Leda Orus Aoede Callirrhoe Autonoe
#         Enceladus Iapetus Umbriel Algieba Despina Erinome Algenib Rasalgethi
#         Laomedeia Achernar Alnilam Schedar Gacrux Pulcherrima Achird
#         Zubenelgenubi Vindemiatrix Sadachbia Sadaltager Sulafat
speak_gemini() {
    local text="$1"
    local key="${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}"
    if [ -z "$key" ]; then
        # Fall back to the login keychain so the key never lives in a dotfile.
        key="$(security find-generic-password -s GEMINI_API_KEY -w 2>/dev/null || true)"
        [ -n "$key" ] && export GEMINI_API_KEY="$key"
    fi
    if [ -z "$key" ]; then
        echo "tts.sh: GEMINI_API_KEY or GOOGLE_API_KEY not set" >&2
        return 1
    fi
    local helper="$(cd "$(dirname "$0")" && pwd)/gemini_tts.py"
    if [ ! -f "$helper" ]; then
        echo "tts.sh: gemini_tts.py missing next to tts.sh" >&2
        return 1
    fi
    echo "[tts] Gemini model=${GEMINI_TTS_MODEL} voice=${GEMINI_TTS_VOICE}" >&2
    rm -f "$OUTPUT"
    if ! GEMINI_TTS_MODEL="$GEMINI_TTS_MODEL" GEMINI_TTS_VOICE="$GEMINI_TTS_VOICE" \
        python3 "$helper" "$text" "$OUTPUT" >/dev/null; then
        return 1
    fi
    [ -s "$OUTPUT" ] || { echo "tts.sh: Gemini produced no audio" >&2; return 1; }
    [ "$TTS_NO_PLAY" = "1" ] && { echo "$OUTPUT"; return 0; }
    play_wav "$OUTPUT"
    rm -f "$OUTPUT"
}
# --- end Google Gemini TTS ----------------------------------------------------

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
    chunks_json=$(split_sentences_json "$text")

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

    text="$(_xai_tag "$text")"

    local input_json
    input_json=$(printf '{"text":%s,"voice_id":"%s","language":"%s"}' \
        "$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$text")" \
        "$voice" "$lang")

    local http_code
    http_code=$(curl -sS -m "${XAI_TTS_TIMEOUT:-180}" \
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
            chunk_text="$(_xai_tag "$chunk_text")"
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

speak_chatterbox_turbo_mlx() {
    local text="$1"
    local lang="$2"

    # English → original base voice; everything else → Lucía latam-ordered.
    # Shadows the global defaults for this call (and everything it calls,
    # including the background chunk subshells, which inherit these bindings).
    local CHATTERBOX_TURBO_MLX_MODEL="$CHATTERBOX_TURBO_MLX_MODEL"
    local CHATTERBOX_TURBO_MLX_REF_AUDIO="$CHATTERBOX_TURBO_MLX_REF_AUDIO"
    case "$lang" in
        en*)
            CHATTERBOX_TURBO_MLX_MODEL="$CHATTERBOX_TURBO_MLX_MODEL_EN"
            CHATTERBOX_TURBO_MLX_REF_AUDIO="$CHATTERBOX_TURBO_MLX_REF_AUDIO_EN"
            ;;
    esac

    [ "$(uname -s 2>/dev/null)" = "Darwin" ] || return 1
    [ -x "$CHATTERBOX_TURBO_MLX_PYTHON" ] || {
        echo "tts.sh: Chatterbox Turbo MLX Python not found: $CHATTERBOX_TURBO_MLX_PYTHON" >&2
        return 1
    }
    [ -d "$CHATTERBOX_TURBO_MLX_MODEL" ] || {
        echo "tts.sh: Chatterbox Turbo MLX model not found: $CHATTERBOX_TURBO_MLX_MODEL" >&2
        return 1
    }

    # Barge-in mode wants a single returned file — skip chunking, one shot.
    if [ "${TTS_NO_PLAY:-0}" = "1" ]; then
        rm -f "$OUTPUT"
        _synth_chatterbox_turbo_mlx "$text" "$lang" "$OUTPUT" || return 1
        echo "$OUTPUT"
        return 0
    fi

    # Long paragraphs make the model struggle/time out — split on . ! ? and
    # synthesize each sentence in parallel, playing each in order as it's ready.
    local chunks_json count
    chunks_json=$(split_sentences_5w_json "$text")
    count=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$chunks_json")

    if [ "$count" -le 1 ]; then
        rm -f "$OUTPUT"
        _synth_chatterbox_turbo_mlx "$text" "$lang" "$OUTPUT" || return 1
        play_wav "$OUTPUT"
        rm -f "$OUTPUT"
        return 0
    fi

    echo "[tts] Chunking into $count sentences (parallel Chatterbox Turbo MLX)" >&2
    _speak_chatterbox_turbo_mlx_chunked "$chunks_json" "$count" "$lang"
}

# Keep at most CHATTERBOX_TURBO_MLX_PARALLELISM chunk syntheses in flight at once.
# Defaults to 1 (sequential) — on Apple Silicon with limited unified memory/GPU
# cores (tested: MacBook Air), running multiple mlx_audio subprocesses concurrently
# audibly corrupts/degrades the output (confirmed by ear: parallelism=4 sounded
# wrong, parallelism=1 on the same text sounded perfect). Raise this only on a
# machine with more GPU headroom (e.g. a Mac Studio) where concurrent MLX
# processes don't contend for the same resources. Launches the next queued chunk
# as soon as a slot frees up, and always plays chunks in order.
: "${CHATTERBOX_TURBO_MLX_PARALLELISM:=1}"
_speak_chatterbox_turbo_mlx_chunked() {
    local chunks_json="$1"
    local count="$2"
    local lang="$3"
    local parallelism="${CHATTERBOX_TURBO_MLX_PARALLELISM:-4}"

    local chunk_dir
    chunk_dir=$(mktemp -d /tmp/opencode-tts-chunks.XXXXXX)

    _launch_chatterbox_chunk() {
        local idx="$1"
        local text wav_prefix
        text=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])[$idx])" "$chunks_json")
        wav_prefix="${chunk_dir}/chunk_$(printf '%03d' "$idx")"
        (
            if _synth_chatterbox_turbo_mlx "$text" "$lang" "${wav_prefix}.wav"; then
                touch "${wav_prefix}.ready"
            else
                echo "[tts] Chatterbox Turbo MLX chunk $idx failed" >&2
                touch "${wav_prefix}.failed"
            fi
        ) &
    }

    local next_to_launch=0
    while [ "$next_to_launch" -lt "$count" ] && [ "$next_to_launch" -lt "$parallelism" ]; do
        _launch_chatterbox_chunk "$next_to_launch"
        next_to_launch=$((next_to_launch + 1))
    done

    local i wav_prefix
    for ((i=0; i<count; i++)); do
        wav_prefix="${chunk_dir}/chunk_$(printf '%03d' $i)"
        while [ ! -f "${wav_prefix}.ready" ] && [ ! -f "${wav_prefix}.failed" ]; do
            sleep 0.05
        done
        [ -f "${wav_prefix}.ready" ] && play_wav "${wav_prefix}.wav"

        if [ "$next_to_launch" -lt "$count" ]; then
            _launch_chatterbox_chunk "$next_to_launch"
            next_to_launch=$((next_to_launch + 1))
        fi
    done

    rm -rf "$chunk_dir"
    return 0
}

# Synthesize one chunk of text to the given output path (fresh model load — the
# CLI has no persistent-server mode, so every call pays load cost). Applies fade.
_synth_chatterbox_turbo_mlx() {
    local text="$1"
    local lang="$2"
    local out_wav="$3"
    local output_dir output_name

    output_dir=$(dirname "$out_wav")
    output_name=$(basename "$out_wav" .wav)
    echo "[tts] Chatterbox Turbo MLX lang=${lang} model=${CHATTERBOX_TURBO_MLX_MODEL}" >&2

    local args=(
        -m mlx_audio.tts.generate
        --model "$CHATTERBOX_TURBO_MLX_MODEL"
        --text "$text"
        --temperature "$CHATTERBOX_TURBO_MLX_TEMPERATURE"
        --top_p "$CHATTERBOX_TURBO_MLX_TOP_P"
        --top_k "$CHATTERBOX_TURBO_MLX_TOP_K"
        --repetition_penalty "$CHATTERBOX_TURBO_MLX_REPETITION_PENALTY"
        --output_path "$output_dir"
        --file_prefix "$output_name"
        --audio_format wav
        --join_audio
    )
    [ -n "$lang" ] && args+=(--lang_code "$lang")
    [ -f "$CHATTERBOX_TURBO_MLX_REF_AUDIO" ] && args+=(--ref_audio "$CHATTERBOX_TURBO_MLX_REF_AUDIO")

    "$CHATTERBOX_TURBO_MLX_PYTHON" "${args[@]}" >/dev/null || return 1
    [ -f "$out_wav" ] && [ -s "$out_wav" ] || {
        echo "tts.sh: Chatterbox Turbo MLX produced no audio" >&2
        return 1
    }
    fade_wav_edges "$out_wav"
}

# --- Qwen3-TTS 12Hz MLX (local, Apple Silicon, in-process; clones ref voice) -
: "${QWEN3_MLX_PYTHON:=$CHATTERBOX_TURBO_MLX_PYTHON}"
: "${QWEN3_MLX_MODEL:=$HOME/mlx-models/qwen3-tts-12hz-1.7b-base-mlx-8bit}"
: "${QWEN3_MLX_REF_AUDIO:=$HOME/chatterbox-finetunino/latam_runs/profiles/lucia-latam-ar-recipe-ordered/reference.wav}"
: "${QWEN3_MLX_REF_AUDIO_EN:=$HOME/voices/qwen3-mlx-carina-en.wav}"
: "${QWEN3_MLX_REF_AUDIO_ES:=$HOME/voices/qwen3-mlx-carina-es.wav}"

# Memory: MLX buffer-cache retention spikes generation to ~13GB footprint on
# this model; cache_limit(0) + a relaxed memory_limit caps it at ~6GB with no
# speed or quality loss (ASR-verified 2026-07-20). A .reftext sidecar next to
# the ref audio skips the in-process Whisper transcription of the reference.
: "${QWEN3_MLX_MEM_LIMIT_GB:=4}"
: "${QWEN3_MLX_CACHE_LIMIT_MB:=512}"
: "${QWEN3_MLX_MAX_TOKENS:=300}"
: "${QWEN3_MLX_CHUNK_WORDS:=25}"
: "${QWEN3_MLX_CHUNK_PAUSE_MS:=350}"
# Lazy resident server: first call spawns it (~10s), later calls are ~2-3s;
# it exits by itself after QWEN3_MLX_TTL_S idle (default 10 min).
: "${QWEN3_MLX_LAZY:=1}"
: "${QWEN3_MLX_PORT:=18885}"
: "${QWEN3_MLX_TTL_S:=600}"
: "${QWEN3_MLX_SERVER:=$HOME/.config/opencode/qwen3_mlx_server.py}"

_qwen3_mlx_server_synth() {
    local text="$1"
    local lang="$2"
    local out_wav="$3"
    local url="http://127.0.0.1:${QWEN3_MLX_PORT}"

    if ! curl -s -m 2 -o /dev/null "$url/health"; then
        [ -f "$QWEN3_MLX_SERVER" ] || return 1
        echo "[tts] Qwen3-TTS MLX spawning lazy server on :${QWEN3_MLX_PORT}…" >&2
        QWEN3_MLX_MODEL="$QWEN3_MLX_MODEL" QWEN3_MLX_REF_AUDIO="$QWEN3_MLX_REF_AUDIO" \
        QWEN3_MLX_MEM_LIMIT_GB="$QWEN3_MLX_MEM_LIMIT_GB" QWEN3_MLX_CACHE_LIMIT_MB="$QWEN3_MLX_CACHE_LIMIT_MB" \
        QWEN3_MLX_MAX_TOKENS="$QWEN3_MLX_MAX_TOKENS" \
        QWEN3_MLX_TTL_S="$QWEN3_MLX_TTL_S" QWEN3_MLX_PORT="$QWEN3_MLX_PORT" \
        nohup "$QWEN3_MLX_PYTHON" "$QWEN3_MLX_SERVER" >> "$HOME/Library/Logs/qwen3-mlx-server.log" 2>&1 &
        local i=0
        while [ $i -lt 45 ]; do
            curl -s -m 2 -o /dev/null "$url/health" && break
            sleep 1; i=$((i + 1))
        done
        curl -s -m 2 -o /dev/null "$url/health" || {
            echo "tts.sh: Qwen3-TTS MLX lazy server failed to start" >&2
            return 1
        }
    fi

    local payload
    payload=$(python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1], "lang_code": sys.argv[2], "ref_audio": sys.argv[3]}))' "$text" "$lang" "$QWEN3_MLX_REF_AUDIO") || return 1
    curl -s -m 120 -X POST "$url/synth" -H 'Content-Type: application/json' \
        -d "$payload" -o "$out_wav" || return 1
    [ -s "$out_wav" ] && head -c 4 "$out_wav" | grep -q 'RIFF' || {
        echo "tts.sh: Qwen3-TTS MLX server returned no audio" >&2
        rm -f "$out_wav"
        return 1
    }
    return 0
}

_synth_qwen3_mlx() {
    local text="$1"
    local lang="$2"
    local out_wav="$3"
    local output_dir output_name ref_text=""

    output_dir=$(dirname "$out_wav")
    output_name=$(basename "$out_wav" .wav)
    [ -f "${QWEN3_MLX_REF_AUDIO%.*}.reftext" ] && ref_text=$(cat "${QWEN3_MLX_REF_AUDIO%.*}.reftext")
    echo "[tts] Qwen3-TTS MLX lang=${lang} model=${QWEN3_MLX_MODEL} ref=$(basename "$QWEN3_MLX_REF_AUDIO") memcap=${QWEN3_MLX_MEM_LIMIT_GB}GB cache=${QWEN3_MLX_CACHE_LIMIT_MB}MiB" >&2

    if [ "$QWEN3_MLX_LAZY" = "1" ] && _qwen3_mlx_server_synth "$text" "$lang" "$out_wav"; then
        fade_wav_edges "$out_wav"
        return 0
    fi
    [ "$QWEN3_MLX_LAZY" = "1" ] && echo "[tts] Qwen3-TTS MLX server route failed → one-shot in-process" >&2

    TTS_TEXT="$text" QWEN3_OUT_DIR="$output_dir" QWEN3_OUT_NAME="$output_name" \
    QWEN3_LANG_CODE="$lang" \
    QWEN3_REF_TEXT="$ref_text" QWEN3_MLX_MODEL="$QWEN3_MLX_MODEL" \
    QWEN3_MLX_REF_AUDIO="$QWEN3_MLX_REF_AUDIO" \
    QWEN3_MLX_MEM_LIMIT_GB="$QWEN3_MLX_MEM_LIMIT_GB" \
    QWEN3_MLX_CACHE_LIMIT_MB="$QWEN3_MLX_CACHE_LIMIT_MB" \
    QWEN3_MLX_MAX_TOKENS="$QWEN3_MLX_MAX_TOKENS" \
    "$QWEN3_MLX_PYTHON" -c '
import os
import mlx.core as mx
mx.set_cache_limit(0)
mx.set_memory_limit(int(float(os.environ["QWEN3_MLX_MEM_LIMIT_GB"]) * 1024**3))
from mlx_audio.tts.generate import generate_audio
ref_text = os.environ.get("QWEN3_REF_TEXT") or None
ref_audio = os.environ.get("QWEN3_MLX_REF_AUDIO") or None
if ref_audio and not os.path.isfile(ref_audio):
    ref_audio = None
generate_audio(
    os.environ["TTS_TEXT"],
    model=os.environ["QWEN3_MLX_MODEL"],
    lang_code=os.environ["QWEN3_LANG_CODE"],
    ref_audio=ref_audio,
    ref_text=ref_text if ref_audio else None,
    max_tokens=int(os.environ["QWEN3_MLX_MAX_TOKENS"]),
    output_path=os.environ["QWEN3_OUT_DIR"],
    file_prefix=os.environ["QWEN3_OUT_NAME"],
    join_audio=True, verbose=False, play=False,
)' >/dev/null || return 1
    [ -f "$out_wav" ] && [ -s "$out_wav" ] || {
        echo "tts.sh: Qwen3-TTS MLX produced no audio" >&2
        return 1
    }
    fade_wav_edges "$out_wav"
}

_concat_qwen3_mlx_chunks() {
    local output="$1"
    local chunk_dir="$2"
    local count="$3"
    local pause_ms="${4:-350}"
    python3 -c '
import os, sys, wave

output, chunk_dir, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
pause_ms = max(0, int(sys.argv[4]))
params = None
frames = []
for index in range(count):
    path = os.path.join(chunk_dir, f"chunk_{index:03d}.wav")
    with wave.open(path, "rb") as wav:
        current = wav.getparams()
        signature = (
            current.nchannels,
            current.sampwidth,
            current.framerate,
            current.comptype,
        )
        if params is None:
            params = current
            expected = signature
        elif signature != expected:
            raise RuntimeError(f"incompatible Qwen3-TTS chunk format: {path}")
        frames.append(wav.readframes(wav.getnframes()))

if params is None:
    raise RuntimeError("no Qwen3-TTS chunks to concatenate")

silence_frames = int(params.framerate * pause_ms / 1000.0)
silence = b"\x00" * silence_frames * params.nchannels * params.sampwidth
with wave.open(output, "wb") as wav:
    wav.setparams(params)
    for index, data in enumerate(frames):
        if index:
            wav.writeframes(silence)
        wav.writeframes(data)
' "$output" "$chunk_dir" "$count" "$pause_ms"
}

speak_qwen3_mlx() {
    local text="$1"
    local lang="$2"
    local reference="$QWEN3_MLX_REF_AUDIO"

    case "$lang" in
        en*) [ -f "$QWEN3_MLX_REF_AUDIO_EN" ] && reference="$QWEN3_MLX_REF_AUDIO_EN" ;;
        es*) [ -f "$QWEN3_MLX_REF_AUDIO_ES" ] && reference="$QWEN3_MLX_REF_AUDIO_ES" ;;
    esac

    [ "$(uname -s 2>/dev/null)" = "Darwin" ] || return 1
    [ -x "$QWEN3_MLX_PYTHON" ] || {
        echo "tts.sh: Qwen3-TTS MLX Python not found: $QWEN3_MLX_PYTHON" >&2
        return 1
    }
    [ -d "$QWEN3_MLX_MODEL" ] || {
        echo "tts.sh: Qwen3-TTS MLX model not found: $QWEN3_MLX_MODEL" >&2
        return 1
    }

    local chunks_json count chunk_dir chunk_text chunk_path i
    chunks_json=$(split_sentences_max_words_json "$text" "$QWEN3_MLX_CHUNK_WORDS") || return 1
    count=$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$chunks_json") || return 1
    [ "$count" -gt 0 ] || return 1

    rm -f "$OUTPUT"
    if [ "$count" -eq 1 ]; then
        QWEN3_MLX_REF_AUDIO="$reference" _synth_qwen3_mlx "$text" "$lang" "$OUTPUT" || return 1
    else
        echo "[tts] Qwen3-TTS MLX autochunk count=${count} max_words=${QWEN3_MLX_CHUNK_WORDS} pause_ms=${QWEN3_MLX_CHUNK_PAUSE_MS}" >&2
        chunk_dir=$(mktemp -d /tmp/qwen3-mlx-chunks.XXXXXX) || return 1
        for ((i=0; i<count; i++)); do
            chunk_text=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[int(sys.argv[2])])' "$chunks_json" "$i") || {
                rm -rf "$chunk_dir"
                return 1
            }
            chunk_path="${chunk_dir}/chunk_$(printf '%03d' "$i").wav"
            echo "[tts] Qwen3-TTS MLX chunk $((i + 1))/${count}: $(printf '%s' "$chunk_text" | wc -w | tr -d ' ') words" >&2
            QWEN3_MLX_REF_AUDIO="$reference" _synth_qwen3_mlx "$chunk_text" "$lang" "$chunk_path" || {
                rm -rf "$chunk_dir"
                return 1
            }
        done
        _concat_qwen3_mlx_chunks "$OUTPUT" "$chunk_dir" "$count" "$QWEN3_MLX_CHUNK_PAUSE_MS" || {
            rm -rf "$chunk_dir"
            return 1
        }
        rm -rf "$chunk_dir"
        fade_wav_edges "$OUTPUT"
    fi
    if [ "${TTS_NO_PLAY:-0}" = "1" ]; then
        echo "$OUTPUT"
        return 0
    fi
    play_wav "$OUTPUT"
    rm -f "$OUTPUT"
}

# --- VibeVoice Realtime MLX (local, Apple Silicon, in-process) --------------
: "${VIBEVOICE_MLX_PYTHON:=$CHATTERBOX_TURBO_MLX_PYTHON}"
: "${VIBEVOICE_MLX_MODEL:=mlx-community/VibeVoice-Realtime-0.5B-6bit}"
: "${VIBEVOICE_MLX_VOICE:=en-Emma_woman}"

_synth_vibevoice_mlx() {
    local text="$1"
    local out_wav="$2"
    local output_dir output_name

    output_dir=$(dirname "$out_wav")
    output_name=$(basename "$out_wav" .wav)
    echo "[tts] VibeVoice MLX voice=${VIBEVOICE_MLX_VOICE} model=${VIBEVOICE_MLX_MODEL}" >&2

    "$VIBEVOICE_MLX_PYTHON" -m mlx_audio.tts.generate \
        --model "$VIBEVOICE_MLX_MODEL" \
        --text "$text" \
        --voice "$VIBEVOICE_MLX_VOICE" \
        --output_path "$output_dir" \
        --file_prefix "$output_name" \
        --audio_format wav \
        --join_audio >/dev/null || return 1
    [ -f "$out_wav" ] && [ -s "$out_wav" ] || {
        echo "tts.sh: VibeVoice MLX produced no audio" >&2
        return 1
    }
    fade_wav_edges "$out_wav"
}

speak_vibevoice_mlx() {
    local text="$1"

    [ "$(uname -s 2>/dev/null)" = "Darwin" ] || return 1
    [ -x "$VIBEVOICE_MLX_PYTHON" ] || {
        echo "tts.sh: VibeVoice MLX Python not found: $VIBEVOICE_MLX_PYTHON" >&2
        return 1
    }

    rm -f "$OUTPUT"
    _synth_vibevoice_mlx "$text" "$OUTPUT" || return 1
    if [ "${TTS_NO_PLAY:-0}" = "1" ]; then
        echo "$OUTPUT"
        return 0
    fi
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
    chunks_json=$(split_sentences_json "$text")
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
# xAI is the default. Local engines (qwen3-mlx, chatterbox, supertonic, qwen,
# neutts, inflect, vibevoice) were removed from the default speak path — they
# do not work on this setup. They remain selectable explicitly via
# TTS_ENGINE=<name>; their internal chains are unchanged. macOS `say` is never
# used as a fallback.
engine="$(printf '%s' "${TTS_ENGINE}" | tr '[:upper:]' '[:lower:]')"
case "$engine" in
    chatterbox-turbo-mlx|chatterbox-turbo|chatterbox-q8|lucia-mlx)
        if speak_chatterbox_turbo_mlx "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Chatterbox Turbo MLX failed → trying Supertonic (local)…" >&2
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic failed → trying NeuTTS (local)…" >&2
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] NeuTTS failed → xAI cloud (last resort)…" >&2
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    qwen3-mlx|qwen-mlx|qwen3-tts-mlx)
        if speak_qwen3_mlx "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Qwen3-TTS MLX failed → trying Chatterbox Turbo MLX (local)…" >&2
        if speak_chatterbox_turbo_mlx "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Chatterbox failed → trying Supertonic (local)…" >&2
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic failed → trying NeuTTS (local)…" >&2
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] NeuTTS failed → xAI cloud (last resort)…" >&2
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    vibevoice-mlx|vibe-mlx|vibevoice-local)
        if speak_vibevoice_mlx "$TEXT"; then exit 0; fi
        echo "[tts] VibeVoice MLX failed → trying Chatterbox Turbo MLX (local)…" >&2
        if speak_chatterbox_turbo_mlx "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Chatterbox failed → trying Supertonic (local)…" >&2
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic failed → trying NeuTTS (local)…" >&2
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] NeuTTS failed → xAI cloud (last resort)…" >&2
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
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
        # Default route: xAI only — no local fallback (local TTS removed).
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: xAI TTS failed; no local fallback available (removed), no macOS say fallback" >&2
        exit 1
        ;;
    gemini|google|google-ai-studio)
        if speak_gemini "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: Gemini TTS failed; explicit Gemini mode has no fallback" >&2
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
        echo "tts.sh: unknown TTS_ENGINE=${TTS_ENGINE}. Use: chatterbox-turbo-mlx, qwen3-mlx, vibevoice-mlx, supertonic, qwen, qwen-lazy, neutts, inflect, openai, xai, gemini." >&2
        exit 2
        ;;
esac
