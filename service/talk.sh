#!/bin/bash
# talk.sh — VAD-driven voice conversation orchestrator
#
# A complete voice conversation cycle in two commands:
#   talk.sh listen   → VAD record + xAI STT → prints transcribed text
#   talk.sh speak    → TTS (xAI voice iris by default), then auto-listen
#
# Depends on:
#   vad_recorder.py  (Silero VAD + sounddevice)
#   tts.sh           (NeuTTS / xAI / VibeVoice / Supertonic)
#   xAI STT          (POST https://api.x.ai/v1/stt — non-streaming)
#
# Usage:
#   talk.sh listen                  — record one utterance, transcribe, print text
#   talk.sh speak "text" [lang]     — speak via TTS (lang: en|es, auto-detected)
#   talk.sh loop                    — continuous conversation loop (standalone)
#   talk.sh status                  — check all services
#   talk.sh devices                 — list audio input devices

set -e

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"

# Cross-platform WAV playback
# macOS: afplay | Linux: ffplay > aplay > paplay > cvlc > mpv
play_wav() {
    local f="$1"
    [ -f "$f" ] || return 1
    case "$(uname -s 2>/dev/null)" in
        Darwin)
            afplay "$f" ;;
        *)
            if command -v ffplay &>/dev/null; then
                ffplay -nodisp -autoexit -loglevel quiet "$f" 2>/dev/null
            elif command -v aplay &>/dev/null; then
                aplay -q "$f" 2>/dev/null
            elif command -v paplay &>/dev/null; then
                paplay "$f" 2>/dev/null
            elif command -v cvlc &>/dev/null; then
                cvlc --play-and-exit --no-video "$f" 2>/dev/null
            elif command -v mpv &>/dev/null; then
                mpv --no-video --quiet "$f" 2>/dev/null
            else
                echo "[talk] No audio player found (install ffmpeg for ffplay)" >&2
                return 1
            fi ;;
    esac
}

# --- Configurable settings ---------------------------------------------------
# Python env (tts-venv with silero-vad, sounddevice, onnxruntime, torch)
: "${PYTHON:=}"  # auto-detect below
# TTS — xAI cloud only. Local engines (qwen3-mlx, chatterbox, supertonic, qwen,
# neutts, inflect, vibevoice) were removed from the default path: they do not
# work on this setup. Override per call with TTS_ENGINE=<engine>.
: "${TTS_ENGINE:=xai}"
# Qwen3-TTS (opt-in): fast 0.6B (:18881) / HQ 1.7B (:18882) MLX servers.
# QWEN_TTS_QUALITY=fast|hq picks which; tts.sh resolves the actual URL.
: "${QWEN_TTS_QUALITY:=hq}"
: "${QWEN_TTS_URL_FAST:=http://127.0.0.1:18881}"
: "${QWEN_TTS_URL_HQ:=http://127.0.0.1:18882}"
: "${QWEN_TTS_URL_LAZY:=http://127.0.0.1:18883}"
case "$(printf '%s' "$QWEN_TTS_QUALITY" | tr '[:upper:]' '[:lower:]')" in
    hq|high|best|1.7b|large)   : "${QWEN_TTS_URL:=$QWEN_TTS_URL_HQ}" ;;
    lazy|lazy-1.7b|qwen-lazy)
        : "${QWEN_TTS_URL:=$QWEN_TTS_URL_LAZY}"
        case "${TTS_ENGINE:-qwen}" in qwen|qwen3|qwen3-tts|qwen-tts|"") TTS_ENGINE=qwen-lazy ;; esac
        ;;
    *)                          : "${QWEN_TTS_URL:=$QWEN_TTS_URL_FAST}" ;;
esac
: "${QWEN_TTS_VOICE:=vivian}"
export QWEN_TTS_QUALITY QWEN_TTS_URL QWEN_TTS_URL_FAST QWEN_TTS_URL_HQ QWEN_TTS_URL_LAZY QWEN_TTS_VOICE
: "${XAI_TTS_VOICE:=iris}"
: "${VIBEVOICE_MODEL:=vibe-realtime-8bit}"
: "${VIBEVOICE_VOICE:=en-Emma_woman}"
: "${VIBEVOICE_VOICE_AUTO:=1}"
: "${VIBEVOICE_CFG_SCALE:=2.0}"
: "${VIBEVOICE_DDPM_STEPS:=15}"
export TTS_ENGINE XAI_TTS_VOICE
# STT: local Parakeet on :5093 — ONNX, CPU, on EVERY platform. setup.sh installs
# the same ONNX server (groxaxo/parakeet-tdt-0.6b-v3-fastapi-openai) with the
# CPU onnxruntime wheel on macOS/Linux/Windows, so the default model is the CPU
# ONNX one everywhere. (Apple Silicon CoreML is opt-in: set STT_MODEL to a CoreML
# model name only if you run a CoreML-backed server.)
: "${STT_MODEL:=parakeet-tdt-0.6b-v3}"
# local | remote | xai. Default is local CoreML Parakeet (launchd com.opencode.parakeet-stt,
# restored 2026-08-23 with the FluidAudio CoreML speech-server on 127.0.0.1:5093).
# Cost: ~0.5 GiB RSS / ~468 MB ANE neural footprint. Switch to `xai` to save it.
: "${STT_ENGINE:=local}"
: "${STT_URL:=http://127.0.0.1:5093/v1/audio/transcriptions}"
: "${STT_REMOTE_URL:=http://127.0.0.1:5093/v1/audio/transcriptions}"
: "${STT_REMOTE_MODEL:=${STT_MODEL}}"
# --- xAI STT (non-streaming) -------------------------------------------------
# NOT OpenAI-compatible: there is no `model` field, and `file` MUST be the last
# multipart field. Response is {text, language, duration, words[]} — the existing
# parser already reads .text. The streaming WebSocket endpoint (wss://api.x.ai/v1/stt)
# is deliberately NOT used; VAD endpointing is handled locally by vad_recorder.py.
: "${XAI_STT_URL:=https://api.x.ai/v1/stt}"
# Leave empty to auto-detect language (needed for es/en code-switching). Setting it
# (e.g. "en") also switches on format=true → Inverse Text Normalization, which
# rewrites spoken numbers/currency/units into written form ("twenty seven" -> "27").
: "${XAI_STT_LANGUAGE:=}"
: "${XAI_STT_FILLER_WORDS:=false}"
# Speech-probability gate, 0.0-1.0 (xAI default 0.5). Lower transcribes quieter
# speech at the cost of spurious text on background noise; 0 disables the gate.
: "${XAI_STT_VAD_THRESHOLD:=}"
# Optional bearer key for a REMOTE STT endpoint (e.g. OpenAI Whisper for slow CPUs).
# Local Parakeet needs none, so this stays empty by default. STT_REMOTE_KEY wins,
# then STT_API_KEY, then OPENAI_API_KEY.
: "${STT_API_KEY:=${STT_REMOTE_KEY:-${OPENAI_API_KEY:-}}}"
# For the xai engine the bearer is XAI_API_KEY (same key as xAI TTS) unless an
# explicit STT key was already provided above.
if [ "${STT_ENGINE}" = "xai" ] && [ -z "${STT_API_KEY:-}" ]; then
    STT_API_KEY="${XAI_API_KEY:-}"
fi
# VAD parameters (passed to vad_recorder.py)
# 700ms trailing silence tolerates natural mid-sentence pauses without cutting
# the turn early; lower to ~500 for snappier (but more interrupt-prone) endpointing.
: "${VAD_MIN_SILENCE_MS:=1500}"
: "${VAD_THRESHOLD:=0.5}"
# Mic device selection
# Default targets the built-in mic and the find_mic() logic explicitly
# excludes "nomachine" (and other virtual adapters).
: "${MIC_QUERY:=}"  # empty = auto-detect best mic; set to substring like "MacBook Air" or "Headset"
# Ready cue before listen (short tone so user knows when to speak)
: "${TALK_READY_CUE:=1}"
# macOS system sound — on Linux/Windows the file won't exist and we fall back to \a beep
: "${TALK_READY_SOUND:=/System/Library/Sounds/Tink.aiff}"
: "${TALK_READY_DELAY_MS:=700}"
# Beep cue: a short synthesized tone played the instant TTS playback ends, so
# the user hears "your turn" and recording begins immediately. Generated once
# and cached (cross-platform, consistent). Set TALK_BEEP=0 to fall back to the
# system ready-sound / terminal bell.
: "${TALK_BEEP:=1}"
: "${TALK_BEEP_MS:=150}"
: "${TALK_BEEP_FREQ:=880}"
: "${TALK_BEEP_FILE:=${TMPDIR:-/tmp}/talk-beep.wav}"
# Guard (ms) added after the beep before the mic goes live, only used by the
# legacy ready-delay path; the signal-driven path activates with no guess.
: "${TALK_LISTEN_GUARD_MS:=200}"
# After speak finishes playback, immediately start listen (stdout = next user text)
: "${TALK_AUTO_LISTEN:=1}"
# Barge-in: detect user speech during TTS playback and interrupt
# WARNING: requires echo cancellation or careful mic placement — TTS audio
# bleeding into the mic will trigger false interrupts. Test before enabling.
: "${TALK_BARGE_IN:=0}"
# Grace period (ms) before barge-in VAD activates after TTS playback starts
# Prevents the VAD from triggering on the initial TTS audio burst
: "${TALK_BARGE_IN_DELAY_MS:=2000}"
# Idle timeout for a single VAD attempt (0=disabled). Conversation mode must
# remain available until the user explicitly ends it, so the default is off.
: "${TALK_IDLE_TIMEOUT_S:=0}"
# Spoken phrases that end the session (case-insensitive substring match,
# pipe-separated). Default: "stop talk". Spanish example: "para de hablar".
# When matched, cmd_listen prints the unambiguous `__TALK_STOP__` marker.
# Empty output is never an end-session signal: it is retried internally.
: "${TALK_STOP_PHRASES:=stop talk}"
# -----------------------------------------------------------------------------

# Auto-detect Python
if [ -z "$PYTHON" ]; then
    for p in ~/.config/opencode/tts-venv/bin/python3; do
        [ -x "$p" ] && { PYTHON="$p"; break; }
    done
    [ -z "$PYTHON" ] && PYTHON="python3"
fi

TTS_SH="${TTS_SH:-$HOME/.config/opencode/tts.sh}"
if [ ! -x "$TTS_SH" ]; then
    TTS_SH="$SERVICE_DIR/tts.sh"
fi
VAD_PY="$SERVICE_DIR/vad_recorder.py"

TTS_LANG_SH="${TTS_LANG_SH:-$HOME/.config/opencode/tts_lang.sh}"
# shellcheck source=/dev/null
[ -f "$TTS_LANG_SH" ] && . "$TTS_LANG_SH"

resolve_stt() {
    if [ "${STT_ENGINE}" = "xai" ]; then
        printf '%s\n%s\n' "$XAI_STT_URL" "xai"
    elif [ "${STT_ENGINE}" = "remote" ]; then
        printf '%s\n%s\n' "${STT_REMOTE_URL:-$STT_URL}" "${STT_REMOTE_MODEL:-$STT_MODEL}"
    else
        printf '%s\n%s\n' "$STT_URL" "$STT_MODEL"
    fi
}

transcribe_file() {
    local file="$1"
    local stt_url="$2"
    local stt_model="$3"
    local response_file http_code

    response_file="$(mktemp /tmp/opencode-stt-response.json.XXXXXX)"
    # Send a bearer header only when a key is set (remote OpenAI-compatible STT).
    local auth_args=()
    [ -n "${STT_API_KEY:-}" ] && auth_args=(-H "Authorization: Bearer ${STT_API_KEY}")
    # Request shape differs per backend. OpenAI-compatible servers take a `model`
    # field; xAI takes none and requires `file` to be the LAST multipart field.
    local form_args=()
    if [ "$stt_model" = "xai" ]; then
        [ -n "${XAI_STT_LANGUAGE:-}" ] && form_args+=(-F "language=${XAI_STT_LANGUAGE}" -F "format=true")
        [ -n "${XAI_STT_VAD_THRESHOLD:-}" ] && form_args+=(-F "vad_threshold=${XAI_STT_VAD_THRESHOLD}")
        form_args+=(-F "filler_words=${XAI_STT_FILLER_WORDS:-false}")
        form_args+=(-F "file=@$file")   # MUST stay last
    else
        form_args+=(-F "file=@$file" -F "model=$stt_model")
    fi

    http_code=$(curl -sS -m "${STT_TIMEOUT_SECONDS:-45}" \
        -o "$response_file" \
        -w '%{http_code}' \
        "${auth_args[@]}" \
        "$stt_url" \
        "${form_args[@]}") || {
        local curl_status=$?
        echo "STT request failed (curl exit $curl_status): $stt_url" >&2
        rm -f "$response_file"
        return 1
    }

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "STT request failed (HTTP $http_code): $stt_url" >&2
        sed -n '1,12p' "$response_file" >&2
        rm -f "$response_file"
        return 1
    fi

    local parse_status=0
    "$PYTHON" - "$response_file" <<'PY' || parse_status=$?
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        payload = json.load(f)
except Exception as exc:
    print(f"STT response was not valid JSON: {exc}", file=sys.stderr)
    sys.exit(1)

if isinstance(payload, dict):
    text = payload.get("text")
    if isinstance(text, str):
        print(text)
        sys.exit(0)
    error = payload.get("error")
    if error:
        print(f"STT error: {error}", file=sys.stderr)
        sys.exit(1)

print(f"STT response did not contain a text field: {payload!r}", file=sys.stderr)
sys.exit(1)
PY
    rm -f "$response_file"
    return "$parse_status"
}

detect_lang() {
    local text="$1"
    if [ -f "$TTS_LANG_SH" ]; then
        resolve_lang "" "$text"
    elif echo "$text" | LC_ALL=C grep -q '[áéíóúñü¿¡ÁÉÍÓÚÑÜ]'; then
        echo "es"
    else
        echo "en"
    fi
}

# Generate the cached beep WAV once (idempotent). Returns 0 if the file exists.
ensure_beep() {
    [ "${TALK_BEEP}" = "0" ] && return 1
    [ -f "$TALK_BEEP_FILE" ] && return 0
    "$PYTHON" - "$TALK_BEEP_FILE" "$TALK_BEEP_FREQ" "$TALK_BEEP_MS" <<'PY' 2>/dev/null || return 1
import sys, wave, math, struct
path, freq, ms = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
sr = 44100
n = int(sr * ms / 1000.0)
fade = max(1, int(sr * 0.012))  # 12ms fade in/out kills clicks
buf = bytearray()
for i in range(n):
    a = math.sin(2 * math.pi * freq * i / sr)
    if i < fade:
        a *= i / fade
    elif i > n - fade:
        a *= (n - i) / fade
    buf += struct.pack('<h', int(a * 0.35 * 32767))
with wave.open(path, 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
    w.writeframes(bytes(buf))
PY
    [ -f "$TALK_BEEP_FILE" ]
}

# Play the beep cue (blocking). Falls back to the terminal bell.
play_beep() {
    [ "${TALK_BEEP}" = "0" ] && return 0
    if ensure_beep; then
        play_wav "$TALK_BEEP_FILE" 2>/dev/null || printf '\a' >&2
    else
        printf '\a' >&2
    fi
}

cmd_ready_cue() {
    [ "${TALK_READY_CUE}" = "0" ] && return 0
    if [ "${TALK_BEEP}" = "1" ] && ensure_beep; then
        play_wav "$TALK_BEEP_FILE" 2>/dev/null || printf '\a'
    elif [ -f "$TALK_READY_SOUND" ]; then
        play_wav "$TALK_READY_SOUND" 2>/dev/null || printf '\a'
    else
        printf '\a'
    fi
}

# True if $1 matches any of the | separated phrases in TALK_STOP_PHRASES
# (case-insensitive substring match). Used by cmd_listen to detect a
# user-initiated session cancel.
# Uses word-splitting (not read -a) for bash 3.2 portability.
is_stop_phrase() {
    local text
    text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    local phrases_lower
    phrases_lower=$(printf '%s' "${TALK_STOP_PHRASES:-stop talk}" | tr '[:upper:]' '[:lower:]')
    local saved_ifs="$IFS"
    IFS='|'
    for phrase in $phrases_lower; do
        [ -z "$phrase" ] && continue
        case "$text" in
            *"$phrase"*) IFS="$saved_ifs"; return 0 ;;
        esac
    done
    IFS="$saved_ifs"
    return 1
}

cmd_listen() {
    if _mic_off; then
        _bus_wait
        return $?
    fi
    local outfile="${1:-opencode-utterance.wav}"
    local ready_delay=0
    [ "${TALK_READY_CUE}" != "0" ] && ready_delay="${TALK_READY_DELAY_MS}"

    # Start VAD recorder BEFORE the ready cue so audio is captured
    # from the moment the user hears the cue. --ready-delay-ms keeps
    # VAD from triggering on cue bleed; ring buffer captures everything.
    local vad_out
    vad_out=$(mktemp /tmp/opencode-vad-output.XXXXXX)

    "$PYTHON" "$VAD_PY" --oneshot \
        --mic-query "$MIC_QUERY" \
        --output-file "$outfile" \
        --vad-threshold "$VAD_THRESHOLD" \
        --min-silence-ms "$VAD_MIN_SILENCE_MS" \
        --ready-delay-ms "$ready_delay" \
        --idle-timeout-s "${TALK_IDLE_TIMEOUT_S:-1440}" \
        2>/dev/null >"$vad_out" &
    local vad_pid=$!

    # Play the ready cue NOW — vad_recorder is already capturing
    cmd_ready_cue >&2

    # Wait for VAD to finish (speech_end, idle_timeout, or error)
    wait "$vad_pid"

    # Parse the JSON output for the WAV file path
    local file
    file=$("$PYTHON" -c "
import json
with open('$vad_out') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            d = json.loads(line)
            if d.get('event') == 'speech_end':
                print(d.get('file',''))
        except: pass
    ")
    rm -f "$vad_out"

    if [ -z "$file" ] || [ ! -f "$file" ]; then
        echo "[talk] No speech captured; continuing to listen" >&2
        cmd_listen "$outfile"
        return
    fi

    # Transcribe (local Parakeet on :5093 — ONNX, CPU, on all platforms)
    local stt_info stt_url stt_model text
    stt_info="$(resolve_stt)"
    stt_url="$(printf '%s\n' "$stt_info" | sed -n '1p')"
    stt_model="$(printf '%s\n' "$stt_info" | sed -n '2p')"
    if ! text=$(transcribe_file "$file" "$stt_url" "$stt_model"); then
        rm -f "$file"
        echo "[talk] Transcription failed; continuing to listen" >&2
        cmd_listen "$outfile"
        return
    fi

    if is_stop_phrase "$text"; then
        echo "[talk] Stop phrase detected (\"$text\"): ending session" >&2
        rm -f "$file"
        echo "__TALK_STOP__"
        return
    fi

    echo "$text"
    rm -f "$file"
}



# --- text bus (mic-free agent-to-agent channel) -------------------------------
# When the mic must stay off (TALK_MIC=off / TALK_NO_MIC=1), agents exchange
# turns as timestamped JSON files under $TALK_BUS_DIR/<date>/ instead of
# speaking into and listening on the same microphone.
TALK_BUS_DIR="${TALK_BUS_DIR:-$HOME/.talk-bus}"
TALK_AGENT="${TALK_AGENT:-agent}"
TALK_BUS_PY="${TALK_BUS_PY:-$SERVICE_DIR/bus/talk_bus.py}"
export TALK_BUS_DIR TALK_AGENT

_mic_off() {
    case "${TALK_MIC:-on}" in
        0|off|no|false|OFF|Off) return 0 ;;
    esac
    [ "${TALK_NO_MIC:-0}" = "1" ] && return 0
    return 1
}

_bus() {
    if [ ! -f "$TALK_BUS_PY" ]; then
        echo "[talk] bus helper missing: $TALK_BUS_PY" >&2
        return 1
    fi
    python3 "$TALK_BUS_PY" "$@"
}

# Record every outgoing turn so the other agent can pick up from it later,
# whether or not the mic is in play.
_bus_post() {
    [ "${TALK_BUS_LOG:-1}" = "1" ] || return 0
    _bus post "$1" "${2:-}" >/dev/null 2>&1 || true
}

# Block until another agent posts a turn; prints its text (same stdout contract
# as `listen`), or nothing on timeout so the caller exits the loop.
_bus_wait() {
    echo "[talk] mic off — waiting on the text bus ($TALK_BUS_DIR) as '$TALK_AGENT'" >&2
    _bus wait "${TALK_BUS_TIMEOUT_S:-${TALK_IDLE_TIMEOUT_S:-1440}}"
}
# --- end text bus -------------------------------------------------------------


# --- global audio lock -------------------------------------------------------
# Prevents two agents (Claude, Codex, opencode, Hermes) from speaking over each
# other on the same speakers: TTS playback is serialized across processes.
TALK_AUDIO_LOCK="${TALK_AUDIO_LOCK:-/tmp/talk-audio.lock}"
TALK_LOCK_TIMEOUT_S="${TALK_LOCK_TIMEOUT_S:-300}"
_talk_lock_held=0

_talk_lock_release() {
    [ "$_talk_lock_held" = "1" ] || return 0
    rm -rf "$TALK_AUDIO_LOCK" 2>/dev/null || true
    _talk_lock_held=0
}

_talk_lock_acquire() {
    [ "${TALK_AUDIO_LOCK_DISABLE:-0}" = "1" ] && return 0
    local waited=0 owner
    while ! mkdir "$TALK_AUDIO_LOCK" 2>/dev/null; do
        owner=$(cat "$TALK_AUDIO_LOCK/pid" 2>/dev/null || true)
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            echo "[talk] clearing stale audio lock (pid $owner)" >&2
            rm -rf "$TALK_AUDIO_LOCK" 2>/dev/null || true
            continue
        fi
        [ "$waited" = "0" ] && echo "[talk] another agent is speaking; waiting for the audio lock" >&2
        sleep 0.2
        waited=$((waited + 1))
        if [ "$waited" -gt $((TALK_LOCK_TIMEOUT_S * 5)) ]; then
            echo "[talk] audio lock timeout after ${TALK_LOCK_TIMEOUT_S}s; taking it over" >&2
            rm -rf "$TALK_AUDIO_LOCK" 2>/dev/null || true
            mkdir "$TALK_AUDIO_LOCK" 2>/dev/null || true
            break
        fi
    done
    printf '%s' "$$" > "$TALK_AUDIO_LOCK/pid" 2>/dev/null || true
    _talk_lock_held=1
    trap '_talk_lock_release' EXIT INT TERM
    return 0
}
# --- end global audio lock ---------------------------------------------------

cmd_speak() {
    local text="$1"
    local lang="${2:-$(detect_lang "$text")}"

    _talk_lock_acquire
    _bus_post "$text" "$lang"

    # Mic-off mode: speak (unless silenced) and take the next turn from the bus.
    if _mic_off; then
        if [ "${TALK_SILENT:-0}" != "1" ]; then
            TTS_ENGINE="$TTS_ENGINE" bash "$TTS_SH" "$text" "$lang" \
                || echo "[talk] TTS failed for text: $text" >&2
        fi
        _talk_lock_release
        if [ "${TALK_AUTO_LISTEN}" = "1" ]; then
            _bus_wait
        fi
        return 0
    fi


    if [ "${TALK_BARGE_IN}" = "1" ] && [ "${TALK_AUTO_LISTEN}" = "1" ]; then
        # Barge-in mode: generate TTS, play with background monitoring
        if _speak_with_barge_in "$text" "$lang"; then
            _talk_lock_release
            return 0
        fi
        echo "[talk] Barge-in failed, falling back to simple mode" >&2
    fi

    # Pre-record mode: start the VAD recorder BEFORE TTS playback so the mic is
    # already open and torch is already loaded — no gap when playback ends. The
    # recorder stays armed-but-ignoring (large ready-delay) during playback, then
    # talk.sh sends SIGUSR1 to flip it live the *instant* the audio + beep finish.
    # Event-driven activation — no guessed timing, so it feels immediate.
    if [ "${TALK_AUTO_LISTEN}" = "1" ]; then
        local tts_wav
        tts_wav=$(TTS_NO_PLAY=1 TTS_ENGINE="$TTS_ENGINE" \
            VIBEVOICE_MODEL="${VIBEVOICE_MODEL:-vibe-realtime-8bit}" \
            VIBEVOICE_VOICE="${VIBEVOICE_VOICE:-en-Emma_woman}" \
            VIBEVOICE_VOICE_AUTO="${VIBEVOICE_VOICE_AUTO:-1}" \
            VIBEVOICE_CFG_SCALE="${VIBEVOICE_CFG_SCALE:-2.0}" \
            VIBEVOICE_DDPM_STEPS="${VIBEVOICE_DDPM_STEPS:-15}" \
            VIBEVOICE_WS_URI="${VIBEVOICE_WS_URI:-ws://127.0.0.1:8010/ws/tts}" \
            bash "$TTS_SH" "$text" "$lang" 2>/dev/null) || true

        if [ -n "$tts_wav" ] && [ -f "$tts_wav" ]; then
            # Pre-generate the beep now so the cue is instant at hand-off.
            ensure_beep || true

            # Large ready-delay = safety net only; SIGUSR1 is the real trigger.
            # If the signal somehow never lands, the mic still opens after this.
            local vad_out vad_pid
            vad_out=$(mktemp /tmp/opencode-vad-output.XXXXXX)
            "$PYTHON" "$VAD_PY" --oneshot \
                --mic-query "$MIC_QUERY" \
                --output-file "${TMPDIR:-/tmp}/opencode-utterance.wav" \
                --vad-threshold "$VAD_THRESHOLD" \
                --min-silence-ms "$VAD_MIN_SILENCE_MS" \
                --ready-delay-ms 600000 \
                --idle-timeout-s "${TALK_IDLE_TIMEOUT_S:-1440}" \
                2>/dev/null >"$vad_out" &
            vad_pid=$!

            sleep 0.05  # let sounddevice open the mic + register SIGUSR1

            play_wav "$tts_wav"        # speak the reply (blocking)
            rm -f "$tts_wav"
            play_beep                  # cue the instant speech ends
            _talk_lock_release         # audio done: let other agents speak
            kill -USR1 "$vad_pid" 2>/dev/null  # flip the recorder live now
            echo "Listening…" >&2

            wait "$vad_pid"

            local file
            file=$("$PYTHON" -c "
import json
with open('$vad_out') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            d = json.loads(line)
            if d.get('event') == 'speech_end':
                print(d.get('file',''))
        except: pass
")
            rm -f "$vad_out"

            if [ -n "$file" ] && [ -f "$file" ]; then
                local stt_info stt_url stt_model text
                stt_info="$(resolve_stt)"
                stt_url="$(printf '%s\n' "$stt_info" | sed -n '1p')"
                stt_model="$(printf '%s\n' "$stt_info" | sed -n '2p')"
                if text=$(transcribe_file "$file" "$stt_url" "$stt_model"); then
                    if is_stop_phrase "$text"; then
                        echo "[talk] Stop phrase detected (\"$text\"): ending session" >&2
                        rm -f "$file"
                        echo "__TALK_STOP__"
                        return
                    fi
                    echo "$text"
                    rm -f "$file"
                    return 0
                fi
                rm -f "$file"
            fi
            echo "[talk] No speech captured; continuing to listen" >&2
            cmd_listen
            return
        fi

        echo "[talk] TTS pre-generation failed, falling back to simple mode" >&2
    fi

    # Simple mode (fallback): TTS generates + plays, then listen
    if ! TTS_ENGINE="$TTS_ENGINE" \
    VIBEVOICE_MODEL="${VIBEVOICE_MODEL:-vibe-realtime-8bit}" \
    VIBEVOICE_VOICE="${VIBEVOICE_VOICE:-en-Emma_woman}" \
    VIBEVOICE_VOICE_AUTO="${VIBEVOICE_VOICE_AUTO:-1}" \
    VIBEVOICE_CFG_SCALE="${VIBEVOICE_CFG_SCALE:-2.0}" \
    VIBEVOICE_DDPM_STEPS="${VIBEVOICE_DDPM_STEPS:-15}" \
    VIBEVOICE_WS_URI="${VIBEVOICE_WS_URI:-ws://127.0.0.1:8010/ws/tts}" \
        bash "$TTS_SH" "$text" "$lang"; then
        _talk_lock_release
        echo "[talk] TTS failed for text: $text" >&2
        if [ "${TALK_AUTO_LISTEN}" = "1" ]; then
            echo "[talk] Continuing to listen despite TTS failure" >&2
            cmd_listen
        fi
        return 0
    fi

    _talk_lock_release
    if [ "${TALK_AUTO_LISTEN}" = "1" ]; then
        echo "Listening for your reply…" >&2
        cmd_listen
    fi
}

_speak_with_barge_in() {
    local text="$1"
    local lang="$2"
    local wav_file=""

    # Step 1: Generate TTS without playing (get WAV path)
    wav_file=$(TTS_NO_PLAY=1 \
        TTS_ENGINE="$TTS_ENGINE" \
        VIBEVOICE_MODEL="${VIBEVOICE_MODEL:-vibe-realtime-8bit}" \
        VIBEVOICE_VOICE="${VIBEVOICE_VOICE:-en-Emma_woman}" \
        VIBEVOICE_VOICE_AUTO="${VIBEVOICE_VOICE_AUTO:-1}" \
        VIBEVOICE_CFG_SCALE="${VIBEVOICE_CFG_SCALE:-2.0}" \
        VIBEVOICE_DDPM_STEPS="${VIBEVOICE_DDPM_STEPS:-15}" \
        VIBEVOICE_WS_URI="${VIBEVOICE_WS_URI:-ws://127.0.0.1:8010/ws/tts}" \
            bash "$TTS_SH" "$text" "$lang" 2>/dev/null) || {
        # TTS generation failed, fall back to simple mode
        echo "[talk] TTS generation failed" >&2
        return 1
    }

    if [ -z "$wav_file" ] || [ ! -f "$wav_file" ]; then
        echo "[talk] TTS produced no audio file" >&2
        return 1
    fi

    # Step 2: Start playback in background
    play_wav "$wav_file" &
    local play_pid=$!

    # Step 3: Start barge-in VAD monitor in parallel
    local barge_result=""
    barge_result=$("$PYTHON" "$VAD_PY" --barge-in \
        --mic-query "$MIC_QUERY" \
        --vad-threshold "$VAD_THRESHOLD" \
        --ready-delay-ms "${TALK_BARGE_IN_DELAY_MS:-2000}" \
        --idle-timeout-s "0" \
        2>/dev/null) &
    local vad_pid=$!

    # Step 4: Wait for either to finish
    # Poll both PIDs until one exits
    local interrupted=0
    while true; do
        if ! kill -0 "$play_pid" 2>/dev/null; then
            # Playback finished naturally
            interrupted=0
            break
        fi
        if ! kill -0 "$vad_pid" 2>/dev/null; then
            # VAD detected speech (barge-in!)
            interrupted=1
            break
        fi
        sleep 0.05
    done

    # Step 5: Clean up
    if [ "$interrupted" = "1" ]; then
        # User spoke — kill playback
        kill "$play_pid" 2>/dev/null
        wait "$play_pid" 2>/dev/null
        echo "[talk] Barge-in detected, interrupting playback" >&2
    else
        # Playback finished — kill VAD monitor
        kill "$vad_pid" 2>/dev/null
        wait "$vad_pid" 2>/dev/null
    fi

    # Cleanup WAV file
    rm -f "$wav_file"

    # Step 6: Start listening for the user's utterance
    if [ "${TALK_AUTO_LISTEN}" = "1" ]; then
        echo "Listening for your reply…" >&2
        cmd_listen
    fi
}

cmd_loop() {
    echo "Talk loop — Ctrl+C to stop" >&2
    while true; do
        local text
        text=$(cmd_listen)
        if [ -n "$text" ]; then
            echo "" >&2
            echo "User: $text" >&2
            echo -n "Response: " >&2
            # Support both interactive (tty) and piped (agent) stdin
            local response=""
            if [ -t 0 ]; then
                # Interactive terminal: read from keyboard
                read -r response
            else
                # Piped stdin (from agent): read next line
                IFS= read -r response || break
            fi
            if [ -n "$response" ]; then
                TALK_AUTO_LISTEN=1 cmd_speak "$response"
            fi
        fi
    done
}

stt_memory_stats() {
    # Linux/Windows: ONNX Parakeet served by the systemd/Task-Scheduler service.
    if [ "$(uname -s 2>/dev/null)" != "Darwin" ]; then
        local onnx_cache="$HOME/.cache/huggingface/hub/models--istupakov--parakeet-tdt-0.6b-v3-onnx"
        if [ -d "$onnx_cache" ]; then
            echo "  ONNX model on disk: $(du -sh "$onnx_cache" 2>/dev/null | awk '{print $1}')"
        else
            echo "  ONNX model on disk: not found (first STT run will download)"
        fi
        if command -v systemctl >/dev/null 2>&1; then
            local mem
            mem=$(systemctl --user show opencode-parakeet-stt -p MemoryCurrent --value 2>/dev/null)
            if [ -n "$mem" ] && [ "$mem" != "[not set]" ] && [ "$mem" -gt 0 ] 2>/dev/null; then
                awk -v m="$mem" 'BEGIN{printf "  service RSS: %.0f MB\n", m/1048576}'
            fi
        fi
        return 0
    fi

    # macOS default backend = the same ONNX (CPU) Parakeet server as Linux/Windows
    # (groxaxo/parakeet-tdt-0.6b-v3-fastapi-openai, run via launchd). Report it first.
    local onnx_cache="$HOME/.cache/huggingface/hub/models--istupakov--parakeet-tdt-0.6b-v3-onnx"
    if [ -d "$onnx_cache" ]; then
        echo "  ONNX model on disk (CPU default): $(du -sh "$onnx_cache" 2>/dev/null | awk '{print $1}')"
    else
        echo "  ONNX model on disk (CPU default): not found (first STT run will download)"
    fi

    # Optional: a precompiled CoreML speech-server (FluidAudio), only if you run one.
    local parakeet_dir="$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3"
    if [ -d "$parakeet_dir" ]; then
        echo "  Optional CoreML model on disk: $(du -sh "$parakeet_dir" 2>/dev/null | awk '{print $1}')"
    fi

    local hf_cache="$HOME/.cache/huggingface/hub/models--FluidInference--parakeet-tdt-0.6b-v3-coreml"
    if [ -d "$hf_cache" ]; then
        echo "  CoreML HF cache (optional, safe to delete): $(du -sh "$hf_cache" 2>/dev/null | awk '{print $1}')"
    fi

    local pocket_cache="$HOME/.cache/fluidaudio"
    if [ -d "$pocket_cache" ]; then
        echo "  fluidaudio cache (PocketTTS, optional): $(du -sh "$pocket_cache" 2>/dev/null | awk '{print $1}')"
    fi

    local stt_pid
    stt_pid=$(pgrep -f "${SPEECH_SERVER_BIN:-$HOME/bin/speech-server}" | head -1)
    if [ -z "$stt_pid" ]; then
        echo "  speech-server: not running"
        return 0
    fi

    echo "  speech-server PID: $stt_pid"
    ps -p "$stt_pid" -o rss=,%cpu= 2>/dev/null | awk '{printf "  ps RSS (app only): %.0f MB  CPU: %s%%\n", $1/1024, $2}'
    if command -v footprint >/dev/null 2>&1; then
        footprint "$stt_pid" 2>/dev/null | awk '
            /Footprint:/ { sub(/^.*Footprint: /,""); fp=$0 }
            /phys_footprint:/ && !/peak/ { phys=$2" "$3 }
            /phys_footprint_peak:/ { phys_peak=$2" "$3 }
            /neural_peak:/ { neural=$2" "$3 }
            END {
                if (fp) printf "  footprint total: %s\n", fp
                if (phys) printf "  phys footprint (dirty app RAM): %s\n", phys
                if (phys_peak) printf "  phys footprint peak: %s\n", phys_peak
                if (neural) printf "  neural_peak (CoreML/ANE model): %s\n", neural
            }'
    fi
}

cmd_status() {
    echo "=== Audio Input Devices ==="
    "$PYTHON" "$VAD_PY" --list-devices 2>&1 | grep -v '^$'
    echo ""
    echo "=== Selected Microphone (MIC_QUERY=${MIC_QUERY:-<unset — system default wins>}) ==="
    if [ -n "$MIC_QUERY" ]; then
        "$PYTHON" "$VAD_PY" --print-selected-mic --mic-query "$MIC_QUERY" 2>&1 || echo "(selection failed)"
    else
        "$PYTHON" "$VAD_PY" --print-selected-mic 2>&1 || echo "(selection failed)"
    fi
    echo ""

    echo "=== TTS (engine=$TTS_ENGINE) ==="
    if [ "$TTS_ENGINE" = "qwen3-mlx" ] || [ "$TTS_ENGINE" = "qwen-mlx" ] || [ "$TTS_ENGINE" = "qwen3-tts-mlx" ]; then
        echo "  Model: ${QWEN3_MLX_MODEL}"
        echo "  Quantization: MLX W8 (8-bit, group size 64)"
        echo "  English reference: ${QWEN3_MLX_REF_AUDIO_EN:-$HOME/voices/qwen3-mlx-carina-en.wav}"
        echo "  Spanish reference: ${QWEN3_MLX_REF_AUDIO_ES:-$HOME/voices/qwen3-mlx-carina-es.wav}"
        echo "  Lazy server: http://127.0.0.1:${QWEN3_MLX_PORT:-18885}"
        echo "  Metal cache: ${QWEN3_MLX_CACHE_LIMIT_MB:-512} MiB"
        echo "  Chunking: ${QWEN3_MLX_CHUNK_WORDS:-25} words, ${QWEN3_MLX_CHUNK_PAUSE_MS:-350} ms pause"
        if [ -d "${QWEN3_MLX_MODEL}" ]; then
            echo "  Checkpoint: present"
        else
            echo "  Checkpoint: MISSING"
        fi
    elif [ "$TTS_ENGINE" = "qwen" ] || [ "$TTS_ENGINE" = "qwen3" ] || [ "$TTS_ENGINE" = "qwen3-tts" ] || [ "$TTS_ENGINE" = "qwen-lazy" ] || [ "$TTS_ENGINE" = "lazy" ]; then
        local qwen_url="${QWEN_TTS_URL:-http://127.0.0.1:18881}"
        echo "  Quality: ${QWEN_TTS_QUALITY:-fast}  (fast=0.6B :18881 · hq=1.7B :18882 · lazy=1.7B :18883 auto-start)"
        echo "  Active URL: $qwen_url"
        echo "  Voice: ${QWEN_TTS_VOICE:-serena}   Model: ${QWEN_TTS_MODEL:-qwen3-tts}"
        local _qu _qname
        for _qu in "${QWEN_TTS_URL_FAST:-http://127.0.0.1:18881}|fast-0.6B" "${QWEN_TTS_URL_HQ:-http://127.0.0.1:18882}|hq-1.7B" "${QWEN_TTS_URL_LAZY:-http://127.0.0.1:18883}|lazy-1.7B(idle-5m)"; do
            _qname="${_qu##*|}"; _qu="${_qu%%|*}"
            if curl -sf -m 2 "$_qu/health" >/dev/null 2>&1; then
                echo "    $_qname $_qu — RUNNING ($(curl -sf -m 2 "$_qu/health" | "$PYTHON" -c "import json,sys; h=json.load(sys.stdin); print('ready' if h.get('backend',{}).get('ready') else h.get('status','?'))" 2>/dev/null || echo ok))"
            else
                echo "    $_qname $_qu — not reachable"
            fi
        done
    elif [ "$TTS_ENGINE" = "xai" ]; then
        echo "  xAI voice: ${XAI_TTS_VOICE:-eve}"
        echo "  xAI model: ${XAI_TTS_MODEL:-grok-2-audio}"
        echo "  API key: $([ -n "${XAI_API_KEY:-}" ] && echo 'set' || echo 'NOT SET')"
        echo "  Fallback: none (xAI only; local TTS removed); macOS say disabled"
    elif [ "$TTS_ENGINE" = "vibevoice" ] || [ "$TTS_ENGINE" = "vibe" ] || [ "$TTS_ENGINE" = "mlx-vibe" ]; then
        echo "  VibeVoice model: ${VIBEVOICE_MODEL:-vibe-realtime-8bit}"
        echo "  VibeVoice voice: ${VIBEVOICE_VOICE:-en-Emma_woman}"
        echo "  Auto voice (es/en): ${VIBEVOICE_VOICE_AUTO:-1}"
        echo "  CFG scale: ${VIBEVOICE_CFG_SCALE:-2.0}"
        echo "  DDPM steps: ${VIBEVOICE_DDPM_STEPS:-15}"
    elif [ "$TTS_ENGINE" = "supertonic" ] || [ "$TTS_ENGINE" = "coreml-tts" ]; then
        echo "  Supertonic 3 URL: ${SUPERTONIC_URL:-http://127.0.0.1:8766}"
        echo "  Voice: ${SUPERTONIC_VOICE:-F4}   Steps: ${SUPERTONIC_STEPS:-20} (${TTS_QUALITY:-high})"
        if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
            echo "  Compute: ${SUPERTONIC_COMPUTE_UNITS:-CPU_AND_NE}"
        else
            echo "  Compute: CPU (ONNX Runtime)"
        fi
    fi
    local vibevoice_http_url="${VIBEVOICE_WS_URI:-ws://127.0.0.1:8010/ws/tts}"
    vibevoice_http_url="$(printf '%s' "$vibevoice_http_url" | sed 's|^ws://|http://|')"
    vibevoice_http_url="${vibevoice_http_url%/ws/tts}/health"
    echo "=== VibeVoice API (${VIBEVOICE_WS_URI:-ws://127.0.0.1:8010/ws/tts}, local MLX) ==="
    if curl -sf -m 2 "$vibevoice_http_url" >/dev/null 2>&1; then
        curl -sf "$vibevoice_http_url" | "$PYTHON" -c "
import json,sys
h=json.load(sys.stdin)
print('  RUNNING — loaded:', ', '.join(h.get('loaded_models') or []) or 'lazy')
print('  models:', ', '.join(h.get('available_models') or []))
" 2>/dev/null || echo "  RUNNING"
    else
        echo "  NOT RUNNING (launchctl kickstart -k gui/\$UID/com.op.tts-multimodel-api)"
    fi
    echo ""

    local stt_model stt_url stt_info
    stt_info="$(resolve_stt)"
    stt_url="$(printf '%s\n' "$stt_info" | sed -n '1p')"
    stt_model="$(printf '%s\n' "$stt_info" | sed -n '2p')"
    echo "=== STT (engine=$STT_ENGINE, model=$stt_model) ==="
    echo "  Endpoint: $stt_url"
    # Strip scheme, then path. Default the port from the scheme when absent,
    # otherwise an https endpoint yields no port and nc always fails.
    local stt_host stt_port stt_scheme
    stt_scheme=$(echo "$stt_url" | sed -n 's|^\([a-z]*\)://.*|\1|p')
    stt_host=$(echo "$stt_url" | sed 's|^[a-z]*://||;s|/.*||')
    case "$stt_host" in
        *:*) stt_port="${stt_host##*:}"; stt_host="${stt_host%:*}" ;;
        *)   [ "$stt_scheme" = "https" ] && stt_port=443 || stt_port=80 ;;
    esac
    if nc -z -w 2 "$stt_host" "$stt_port" 2>/dev/null; then
        echo "  REACHABLE ($stt_host:$stt_port)"
    else
        echo "  NOT REACHABLE ($stt_host:$stt_port)"
    fi
    if [ -n "${XAI_STT_LANGUAGE:-}" ] && [ "${STT_ENGINE}" = "xai" ]; then
        echo "  Language: ${XAI_STT_LANGUAGE} (format=true, ITN on)"
    elif [ "${STT_ENGINE}" = "xai" ]; then
        echo "  Language: auto-detect (ITN off)"
        echo "  API key: $([ -n "${STT_API_KEY:-}" ] && echo 'set' || echo 'NOT SET')"
    fi
    if [ "${STT_ENGINE}" != "remote" ] && [ "${STT_ENGINE}" != "xai" ]; then
        if [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
            if systemctl --user is-active --quiet opencode-parakeet-stt 2>/dev/null; then
                echo "  systemd: opencode-parakeet-stt active"
            else
                echo "  systemd: opencode-parakeet-stt inactive (start: systemctl --user start opencode-parakeet-stt)"
            fi
        elif launchctl print "gui/$(id -u)/com.opencode.parakeet-stt" >/dev/null 2>&1; then
            echo "  launchd: com.opencode.parakeet-stt running"
        else
            echo "  launchd: com.opencode.parakeet-stt not loaded"
        fi
        stt_memory_stats
    fi
    local sample_wav="$HOME/.config/opencode/ref_voice_bench.wav"
    if [ -f "$sample_wav" ]; then
        local sample_text
        if sample_text=$(transcribe_file "$sample_wav" "$stt_url" "$stt_model" 2>/tmp/opencode-stt-status.err); then
            echo "  Self-test: OK — ${sample_text}"
        else
            echo "  Self-test: FAILED"
            sed 's/^/    /' /tmp/opencode-stt-status.err
        fi
        rm -f /tmp/opencode-stt-status.err
    fi
    echo ""

    echo "=== Python Environment ==="
    echo "  Interpreter: $PYTHON"
    echo "  VAD: $VAD_PY"
    echo "  TTS: $TTS_SH"
    echo "  Codex skill: $([ -L "$HOME/.codex/skills/talk" ] && readlink "$HOME/.codex/skills/talk" || echo "not symlinked")"
    echo "  VibeVoice helper: ${VIBEVOICE_SPEAK_PY:-$HOME/tts-multimodel-api/speak_vibevoice.py}"
    echo "  VibeVoice WS: ${VIBEVOICE_WS_URI:-ws://127.0.0.1:8010/ws/tts}"
    echo "  Auto-listen after speak: $([ "$TALK_AUTO_LISTEN" = 1 ] && echo yes || echo no)"
    echo "  Barge-in: $([ "$TALK_BARGE_IN" = 1 ] && echo "enabled (interrupt TTS on speech)" || echo disabled)"
    echo "  Idle timeout: ${TALK_IDLE_TIMEOUT_S:-1440}s (0=disabled)"
    "$PYTHON" -c "
import sounddevice as sd, torch, silero_vad
print('  sounddevice : OK')
print('  torch      :', torch.__version__)
print('  silero-vad :', silero_vad.__version__)
" 2>&1
}

cmd_devices() {
    echo "=== Audio Input Devices ===" >&2
    "$PYTHON" "$VAD_PY" --list-devices
    echo ""
    echo "=== Selected Microphone (MIC_QUERY=${MIC_QUERY:-<unset — system default wins>}) ==="
    if [ -n "$MIC_QUERY" ]; then
        "$PYTHON" "$VAD_PY" --print-selected-mic --mic-query "$MIC_QUERY" 2>&1 || echo "(selection failed)"
    else
        "$PYTHON" "$VAD_PY" --print-selected-mic 2>&1 || echo "(selection failed)"
    fi
}

case "${1:-listen}" in
    listen|record|hear)
        cmd_listen "${2:-opencode-utterance.wav}"
        ;;
    speak|say|tts)
        shift
        cmd_speak "$@"
        ;;
    loop)
        cmd_loop
        ;;
    status|health)
        cmd_status
        ;;
    bus)
        shift
        _bus "$@"
        ;;
    devices|mic|list-devices)
        cmd_devices
        ;;
    *)
        echo "Usage: talk.sh {listen|speak|loop|status|devices|bus {post|read|wait|tail}}" >&2
        exit 1
        ;;
esac
