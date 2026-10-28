#!/usr/bin/env bash
# Provider-safe TTS entry point.
#
# The historical multi-backend dispatcher now lives in tts_backends.sh. This
# wrapper owns every xAI request so raw, untagged text can never reach xAI TTS.
# Before synthesis it runs xai_sentence_tagger.py, verifies a one-tag-per-sentence
# invariant, and only then submits the directed text. Other engines keep their
# existing behavior; if they fail, the final xAI fallback is also tagged here.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_SH="${TTS_BACKEND_SH:-$SCRIPT_DIR/tts_backends.sh}"
TAGGER_PY="${TTS_SENTENCE_TAGGER_PY:-$SCRIPT_DIR/xai_sentence_tagger.py}"
TEXT="${1:-Hello.}"
LANG="${2:-auto}"
ENGINE="$(printf '%s' "${TTS_ENGINE:-supertonic}" | tr '[:upper:]' '[:lower:]')"
XAI_KEY="${XAI_API_KEY:-}"
XAI_URL="${XAI_TTS_URL:-https://api.x.ai/v1/tts}"
XAI_VOICE="$(printf '%s' "${XAI_TTS_VOICE:-eve}" | tr '[:upper:]' '[:lower:]')"
TAG_MODE="${TTS_TAG_MODE:-auto}"
: "${TTS_NO_PLAY:=0}"

# --- conversation audio archive ----------------------------------------------
# Every synthesized utterance is kept as Opus under
# $TALK_AUDIO_DIR/<session>/, so a conversation can be replayed and later merged
# into a single file. Opus keeps speech quality at a fraction of WAV's size.
TALK_AUDIO_DIR="${TALK_AUDIO_DIR:-$HOME/.talk-audio}"
TALK_AUDIO_BITRATE="${TALK_AUDIO_BITRATE:-32k}"

_archive_session_dir() {
    local s="${TALK_SESSION:-}"
    if [ -z "$s" ]; then
        # One session per calendar day per agent unless TALK_SESSION is set.
        s="$(date -u +%Y-%m-%d)-${TALK_AGENT:-agent}"
    fi
    local d="$TALK_AUDIO_DIR/$s"
    mkdir -p "$d" 2>/dev/null || return 1
    printf '%s' "$d"
}

# _archive_audio <wav-or-audio-file> [role]
_archive_audio() {
    [ "${TALK_AUDIO_ARCHIVE:-1}" = "1" ] || return 0
    local src="$1" role="${2:-spoken}"
    [ -f "$src" ] && [ -s "$src" ] || return 0
    command -v ffmpeg >/dev/null 2>&1 || return 0
    local dir stamp out
    dir="$(_archive_session_dir)" || return 0
    stamp="$(date -u +%Y%m%dT%H%M%S)-$$"
    out="$dir/${stamp}-${role}-${TALK_AGENT:-agent}.opus"
    ffmpeg -nostdin -y -loglevel error -i "$src" \
        -c:a libopus -b:a "$TALK_AUDIO_BITRATE" -ar 48000 -ac 1 \
        "$out" >/dev/null 2>&1 || return 0
    return 0
}
# --- end conversation audio archive ------------------------------------------


play_wav() {
    local file="$1"
    [ -f "$file" ] || return 1
    _archive_audio "$file" spoken
    case "$(uname -s 2>/dev/null)" in
        Darwin) afplay "$file" ;;
        *)
            if command -v ffplay >/dev/null 2>&1; then
                ffplay -nodisp -autoexit -loglevel quiet "$file" 2>/dev/null
            elif command -v aplay >/dev/null 2>&1; then
                aplay -q "$file" 2>/dev/null
            elif command -v paplay >/dev/null 2>&1; then
                paplay "$file" 2>/dev/null
            elif command -v cvlc >/dev/null 2>&1; then
                cvlc --play-and-exit --no-video "$file" 2>/dev/null
            elif command -v mpv >/dev/null 2>&1; then
                mpv --no-video --quiet "$file" 2>/dev/null
            else
                echo "[tts] No audio player found (install ffmpeg for ffplay)" >&2
                return 1
            fi ;;
    esac
}

run_backends_without_xai() {
    local requested_engine="$1"
    if [ ! -x "$BACKEND_SH" ]; then
        echo "tts.sh: backend dispatcher is missing or not executable: $BACKEND_SH" >&2
        return 1
    fi
    # Clear credentials even for older/custom dispatchers, so an xAI attempt
    # must return to this wrapper and its sentence-tag invariant.
    XAI_API_KEY= TTS_ENGINE="$requested_engine" bash "$BACKEND_SH" "$TEXT" "$LANG"
}

build_xai_request() {
    local report_file="$1"
    local request_file="$2"
    python3 - "$report_file" "$request_file" "$XAI_VOICE" "$LANG" "$TEXT" "$SCRIPT_DIR" <<'PY'
import json
import sys

report_path, request_path, voice, language, source_text, script_dir = sys.argv[1:]
sys.path.insert(0, script_dir)
from xai_sentence_tagger import sentence_spans, validate_tagged_sentence
source_sentences = sentence_spans(source_text)
with open(report_path, encoding="utf-8") as handle:
    report = json.load(handle)

sentences = report.get("sentences")
sentence_count = report.get("sentence_count")
tagged_count = report.get("tagged_sentence_count")
untagged = report.get("untagged_sentence_indexes")
if not isinstance(sentence_count, int) or sentence_count < 1:
    raise SystemExit("sentence tagger returned an invalid sentence_count")
if tagged_count != sentence_count or untagged != []:
    raise SystemExit(
        f"sentence tag invariant failed: {tagged_count}/{sentence_count}; untagged={untagged}"
    )
if sentence_count != len(source_sentences):
    raise SystemExit("sentence tagger changed the source sentence count")
if not isinstance(sentences, list) or len(sentences) != sentence_count:
    raise SystemExit("sentence tagger returned an incomplete sentence list")
for expected, row in enumerate(sentences):
    if not isinstance(row, dict) or row.get("index") != expected:
        raise SystemExit("sentence tagger returned missing, duplicate, or unordered indexes")
    original = source_sentences[expected].text
    candidate = row.get("tagged_text")
    if row.get("original") != original or not isinstance(candidate, str):
        raise SystemExit(f"sentence {expected} changed the original text")
    errors, tags = validate_tagged_sentence(original, candidate)
    if errors or row.get("tags") != tags:
        raise SystemExit(f"sentence {expected} has invalid xAI tags")

tagged_text = report.get("tagged_text")
if not isinstance(tagged_text, str) or not tagged_text:
    raise SystemExit("sentence tagger returned no tagged_text")

cursor = 0
rebuilt = []
for span, row in zip(source_sentences, sentences):
    rebuilt.extend((source_text[cursor:span.start], row["tagged_text"]))
    cursor = span.end
rebuilt.append(source_text[cursor:])
if tagged_text != "".join(rebuilt):
    raise SystemExit("sentence tagger text does not match its sentence proof")

payload = {
    "text": tagged_text,
    "voice_id": voice,
    "language": language or "auto",
    "output_format": {"codec": "wav", "sample_rate": 48000},
}
with open(request_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False)
print(f"{tagged_count}/{sentence_count}")
PY
}

speak_xai_tagged() {
    if [ -z "$XAI_KEY" ]; then
        echo "tts.sh: XAI_API_KEY not set" >&2
        return 1
    fi
    if [ ! -f "$TAGGER_PY" ]; then
        echo "tts.sh: sentence tagger is missing: $TAGGER_PY" >&2
        return 1
    fi

    local report_file request_file output_file tag_status http_code
    report_file="$(mktemp "${TMPDIR:-/tmp}/opencode-xai-tags.XXXXXX")"
    request_file="$(mktemp "${TMPDIR:-/tmp}/opencode-xai-request.XXXXXX")"
    output_file="$(mktemp "${TMPDIR:-/tmp}/opencode-xai-tagged.XXXXXX")"

    if ! printf '%s' "$TEXT" | python3 "$TAGGER_PY" \
        --language "$LANG" --mode "$TAG_MODE" --format json >"$report_file"; then
        echo "tts.sh: xAI sentence tagging failed" >&2
        rm -f "$report_file" "$request_file" "$output_file"
        return 1
    fi
    if ! tag_status="$(build_xai_request "$report_file" "$request_file")"; then
        echo "tts.sh: xAI sentence-tag invariant failed" >&2
        rm -f "$report_file" "$request_file" "$output_file"
        return 1
    fi

    echo "[tts] xAI voice=${XAI_VOICE} lang=${LANG} tagged_sentences=${tag_status} mode=${TAG_MODE}" >&2
    http_code="$(curl -sS -m "${XAI_TTS_TIMEOUT_SECONDS:-180}" \
        -o "$output_file" -w '%{http_code}' \
        "$XAI_URL" \
        -H "Authorization: Bearer $XAI_KEY" \
        -H "Content-Type: application/json" \
        --data-binary "@$request_file")" || {
        echo "tts.sh: xAI request failed (curl exit $?)" >&2
        rm -f "$report_file" "$request_file" "$output_file"
        return 1
    }
    rm -f "$report_file" "$request_file"

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "tts.sh: xAI HTTP $http_code" >&2
        rm -f "$output_file"
        return 1
    fi
    if [ ! -s "$output_file" ]; then
        echo "tts.sh: xAI produced no audio" >&2
        rm -f "$output_file"
        return 1
    fi

    if [ "$TTS_NO_PLAY" = "1" ]; then
        echo "$output_file"
        return 0
    fi
    play_wav "$output_file"
    rm -f "$output_file"
}

case "$ENGINE" in
    xai|grok|x-ai)
        if speak_xai_tagged; then
            exit 0
        fi
        echo "[tts] Tagged xAI failed → trying local backends…" >&2
        run_backends_without_xai supertonic
        ;;
    gemini|google|google-ai-studio)
        run_backends_without_xai "$ENGINE"
        ;;
    *)
        backend_status=0
        if run_backends_without_xai "$ENGINE"; then
            exit 0
        else
            backend_status=$?
        fi
        # Preserve terminal dispatcher semantics: unknown engines (2) and explicit
        # credential refusals such as Inworld 401/403 (3) must not be masked.
        case "$backend_status" in
            2|3) exit "$backend_status" ;;
        esac
        if [ -n "$XAI_KEY" ]; then
            echo "[tts] Local/selected backends failed → trying sentence-tagged xAI…" >&2
            speak_xai_tagged
        else
            exit "$backend_status"
        fi
        ;;
esac
