#!/usr/bin/env bash
# Local VoiceMode TTS_SH adapter for AI Sentence Tagger / AI Voice Studio.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${AI_TTS_PYTHON:-python3}"
TEXT="${1:-Hello.}"
LANGUAGE="${2:-auto}"

play_audio() {
    local file="$1"
    case "$(uname -s 2>/dev/null)" in
        Darwin)
            afplay "$file"
            ;;
        *)
            if command -v ffplay >/dev/null 2>&1; then
                ffplay -nodisp -autoexit -loglevel quiet "$file" 2>/dev/null
            elif command -v aplay >/dev/null 2>&1; then
                aplay -q "$file" 2>/dev/null
            elif command -v paplay >/dev/null 2>&1; then
                paplay "$file" 2>/dev/null
            elif command -v mpv >/dev/null 2>&1; then
                mpv --no-video --quiet "$file" 2>/dev/null
            else
                echo "ai-tts-provider: no supported audio player found" >&2
                return 1
            fi
            ;;
    esac
}

output_path="$(
    "$PYTHON" "$SCRIPT_DIR/tts_provider.py" synthesize \
        --text "$TEXT" \
        --language "$LANGUAGE"
)"

if [ ! -s "$output_path" ]; then
    echo "ai-tts-provider: synthesis returned no audio file" >&2
    exit 1
fi

if [ "${TTS_NO_PLAY:-0}" = "1" ]; then
    printf '%s\n' "$output_path"
    exit 0
fi

trap 'rm -f "$output_path"' EXIT
play_audio "$output_path"
