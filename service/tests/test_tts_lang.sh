#!/bin/bash
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TTS_LANG_SH="${ROOT}/../../tts_lang.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    expected="$1"
    actual="$2"
    label="$3"
    [ "$expected" = "$actual" ] || fail "$label: expected '$expected', got '$actual'"
}

# shellcheck source=/dev/null
. "$TTS_LANG_SH"

assert_eq "es" "$(resolve_lang "" "Porque la ultima voz que utilizaste era muy trucha.")" \
    "Spanish speech without accents should be recognized as Spanish"

VIBEVOICE_VOICE="en-Emma_woman"
VIBEVOICE_VOICE_AUTO=0
assert_eq "en-Emma_woman" "$(resolve_vibevoice_voice es)" \
    "Official VibeVoice config should keep the stable English preset unless auto voice is explicitly enabled"

VIBEVOICE_VOICE_AUTO=1
assert_eq "sp-Spk0_woman" "$(resolve_vibevoice_voice es)" \
    "Explicit auto voice should still map detected Spanish to the Spanish preset"

grep -q 'VIBEVOICE_VOICE_AUTO:=0' "$ROOT/talk.sh" || \
    fail "talk.sh should default VIBEVOICE_VOICE_AUTO to 0 for official VibeVoice config"
grep -q 'VIBEVOICE_VOICE_AUTO:=0' "$HOME/.config/opencode/tts.sh" || \
    fail "tts.sh should default VIBEVOICE_VOICE_AUTO to 0 for official VibeVoice config"

echo "OK: tts language and voice selection"
