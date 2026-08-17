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

play_wav() {
    local file="$1"
    [ -f "$file" ] || return 1
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
    # The old dispatcher contains a raw xAI fallback. Clear the key so every xAI
    # request is forced back through this wrapper and its sentence-tag invariant.
    XAI_API_KEY= TTS_ENGINE="$requested_engine" bash "$BACKEND_SH" "$TEXT" "$LANG"
}

build_xai_request() {
    local report_file="$1"
    local request_file="$2"
    python3 - "$report_file" "$request_file" "$XAI_VOICE" "$LANG" <<'PY'
import json
import sys

report_path, request_path, voice, language = sys.argv[1:]
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
if not isinstance(sentences, list) or len(sentences) != sentence_count:
    raise SystemExit("sentence tagger returned an incomplete sentence list")
for expected, row in enumerate(sentences):
    if not isinstance(row, dict) or row.get("index") != expected:
        raise SystemExit("sentence tagger returned missing, duplicate, or unordered indexes")
    if not row.get("tags") or row.get("tagged_text") == row.get("original"):
        raise SystemExit(f"sentence {expected} has no inserted xAI tag")

tagged_text = report.get("tagged_text")
if not isinstance(tagged_text, str) or not tagged_text:
    raise SystemExit("sentence tagger returned no tagged_text")

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
    http_code="$(curl -sS -m "${XAI_TTS_TIMEOUT_SECONDS:-60}" \
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
