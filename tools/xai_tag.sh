#!/usr/bin/env bash
# xai_tag.sh — add xAI TTS speech-direction tags to text, one sentence at a time.
#
#   xai_tag.sh "texto"      # tagged text on stdout
#   echo "texto" | xai_tag.sh
#
# Backed by groxaxo/xai-sentence-tagger installed at ~/.local/share/xai-sentence-tagger.
# Fails open: on any error the original text is echoed unchanged, so TTS never breaks.
set -uo pipefail

TAGGER="${XAI_TAGGER_BIN:-$HOME/.local/share/xai-sentence-tagger/venv/bin/xai-tagger}"
COVERAGE="${XAI_TAG_COVERAGE:-natural}"
LANGUAGE="${XAI_TAG_LANGUAGE:-auto}"
TIMEOUT="${XAI_TAG_TIMEOUT:-20}"

text="${1:-}"
[ -n "$text" ] || text="$(cat)"
[ -n "${text// /}" ] || { printf '%s' "$text"; exit 0; }

# Already tagged (e.g. hand-written tags) — leave it alone.
case "$text" in
    *'['*']'*|*'<'*'>'*) printf '%s' "$text"; exit 0 ;;
esac

if [ ! -x "$TAGGER" ]; then
    printf '%s' "$text"; exit 0
fi

tmp_in=$(mktemp /tmp/xai-tag-in.XXXXXX)
tmp_out=$(mktemp /tmp/xai-tag-out.XXXXXX)
trap 'rm -f "$tmp_in" "$tmp_out"' EXIT
printf '%s\n' "$text" > "$tmp_in"

if command -v timeout >/dev/null 2>&1; then
    RUN=(timeout "$TIMEOUT")
elif command -v gtimeout >/dev/null 2>&1; then
    RUN=(gtimeout "$TIMEOUT")
else
    RUN=()
fi

if "${RUN[@]+"${RUN[@]}"}" "$TAGGER" tag "$tmp_in" -o "$tmp_out" \
        --coverage "$COVERAGE" --language "$LANGUAGE" >/dev/null 2>&1 \
   && [ -s "$tmp_out" ]; then
    tagged="$(cat "$tmp_out")"
    # Sanity: stripping tags must reproduce the source, otherwise discard.
    stripped=$(printf '%s' "$tagged" | sed -E 's/\[[a-z-]+\]//g; s#</?[a-z-]+>##g')
    if [ "$(printf '%s' "$stripped" | tr -d '[:space:]')" = "$(printf '%s' "$text" | tr -d '[:space:]')" ]; then
        printf '%s' "$tagged"
        exit 0
    fi
fi

printf '%s' "$text"
