#!/bin/bash
# inworld_steer.sh — TTS steering pre-processor for inworld-tts-2.
#
# Rewrites plain reply text into inworld-tts-2 steering markup (square-bracket
# natural-language delivery tags) so the spoken audio is expressive instead of
# flat. Used by tts.sh's speak_inworld path (TTS_ENGINE=inworld).
#
# Usage:
#   inworld_steer.sh "<text>" [lang]        # text as arg
#   echo "<text>" | inworld_steer.sh - [lang]
# Prints the tagged text to stdout. On ANY failure it prints the ORIGINAL text
# unchanged (fail-open — never blocks audio generation).
#
# Why per-sentence tags: tts.sh splits the reply on sentence boundaries (.!?)
# and sends EACH sentence as a separate Inworld request, so a tag does not carry
# across sentences. The prompt therefore tags every sentence. tts.sh calls this
# script per-chunk inside its parallel synth jobs so the rewrite overlaps
# synthesis. See docs/providers.md for the full rationale.
#
# Config (env):
#   INWORLD_STEER         auto|1|0   (default auto: on only for inworld-tts-2)
#   INWORLD_TTS_MODEL     used by `auto` to decide (steering only works on tts-2)
#   INWORLD_STEER_MODEL   LLM router model (default openai/gpt-4o-mini)
#   INWORLD_STEER_URL     OpenAI-compatible chat endpoint
#                         (default https://api.inworld.ai/v1/chat/completions)
#   INWORLD_STEER_KEY     auth key (default INWORLD_API_KEY / INWORLD_TTS_API)
#   INWORLD_STEER_PERSONA optional persona line prepended to the system prompt
#   INWORLD_STEER_TIMEOUT curl timeout seconds (default 20)

set -euo pipefail

TEXT="${1:-}"
[ "$TEXT" = "-" ] && TEXT="$(cat)"
LANG_HINT="${2:-}"

# Nothing to do on empty input.
[ -n "$TEXT" ] || { printf '%s' "$TEXT"; exit 0; }

emit_original() { printf '%s' "$TEXT"; exit 0; }

# --- Gate: should we steer at all? -------------------------------------------
mode="${INWORLD_STEER:-auto}"
model_id="${INWORLD_TTS_MODEL:-inworld-tts-2}"
case "$mode" in
    0|off|no|false) emit_original ;;
    auto)
        # Steering is only interpreted by inworld-tts-2; on tts-1 descriptive
        # tags get read aloud verbatim, so skip unless the model is tts-2.
        case "$model_id" in
            *tts-2*) : ;;          # proceed
            *)       emit_original ;;
        esac
        ;;
    *) : ;;  # 1/on/yes/true → always steer
esac

KEY="${INWORLD_STEER_KEY:-${INWORLD_API_KEY:-${INWORLD_TTS_API:-}}}"
[ -n "$KEY" ] || emit_original

URL="${INWORLD_STEER_URL:-https://api.inworld.ai/v1/chat/completions}"
ROUTER_MODEL="${INWORLD_STEER_MODEL:-openai/gpt-4o-mini}"
TIMEOUT="${INWORLD_STEER_TIMEOUT:-20}"
PERSONA="${INWORLD_STEER_PERSONA:-}"

read -r -d '' SYS_PROMPT <<'PROMPT' || true
You are a speech-direction pre-processor for inworld-tts-2. You receive reply text
that is about to be spoken aloud. Rewrite it so it sounds like a real, emotionally
present human, by inserting inworld-tts-2 steering tags. Output ONLY the rewritten
tagged text — no explanations, no quotes, no markdown, no code fences.

How steering works: a steering tag is a natural-language delivery direction inside
square brackets placed at the START of the sentence it applies to: [instruction]
Sentence text. Steering instructions are ALWAYS written in English (lowercase, no
punctuation inside the brackets), even when the spoken text is in another language.

CRITICAL placement rule: the downstream engine sends EACH SENTENCE as a separate
request, so a tag does NOT carry to the next sentence. Put a steering tag at the
start of EVERY sentence. Never leave a sentence untagged. Vary tags naturally so
consecutive sentences are not identical unless the emotion truly holds.

Build expressive instructions by layering emotion + pace + pitch + manner in one
natural phrase, e.g. [say excitedly with a high pitch and fast pace], [say sadly
with deliberate pauses in a low voice and hushed style], [warm and teasing with a
playful lilt and easy pace], [sound concerned with a measured pace and low tone].
Dimensions you can draw from: emotion, articulation, intonation, volume, pitch,
range, speed, vocal style.

Non-verbals (render as real sound, insert inline, at most one or two total):
[laugh] [sigh] [breathe] [clear throat] [cough] [yawn].
Emphasis: CAPITALIZE a word to stress it; partial caps for a syllable. Use sparingly.
Pauses: <break time="500ms" /> only when a deliberate beat adds meaning (max 10s).

HARD RULES:
1. One steering instruction per sentence, at its start. Never stack opposing
   directions in one tag (no whisper + very loud).
2. Match the tag to the meaning of the words; never contradict the content.
3. Keep ALL original meaning and wording. Add direction and light spoken polish
   (contractions, a natural filler where a human would pause). Add no new facts,
   answer nothing differently, drop nothing.
4. Make it speakable: spell numbers/dates/symbols as spoken words in the text's own
   language. Remove markdown, bullets, emojis, URLs, code blocks, asterisks.
5. Steering instructions in English; the spoken text stays in its original language.
6. Output is the tagged text and NOTHING else.
PROMPT

if [ -n "$PERSONA" ]; then
    SYS_PROMPT="Persona: ${PERSONA}
${SYS_PROMPT}"
fi

# Build request JSON safely via python (handles all escaping / unicode).
req=$(python3 -c '
import json, sys
sys_prompt, user_text, model, lang = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
user = user_text if not lang else f"[spoken language: {lang}]\n{user_text}"
print(json.dumps({
    "model": model,
    "temperature": 0.4,
    "max_tokens": 800,
    "messages": [
        {"role": "system", "content": sys_prompt},
        {"role": "user", "content": user},
    ],
}))
' "$SYS_PROMPT" "$TEXT" "$ROUTER_MODEL" "$LANG_HINT") || emit_original

resp=$(curl -sS -m "$TIMEOUT" "$URL" \
    -H "Authorization: Basic $KEY" \
    -H "Content-Type: application/json" \
    -d "$req" 2>/dev/null) || emit_original

# Extract content; fall back to original on any parse problem or empty output.
out=$(python3 -c '
import json, sys, re
try:
    d = json.loads(sys.stdin.read())
    msg = d["choices"][0]["message"]["content"]
except Exception:
    sys.exit(1)
if not msg or not msg.strip():
    sys.exit(1)
s = msg.strip()
# Strip accidental code fences or wrapping quotes.
s = re.sub(r"^```[a-zA-Z]*\n?", "", s)
s = re.sub(r"\n?```$", "", s).strip()
if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"\x27":
    s = s[1:-1].strip()
# Sanity: a steered result should contain at least one [tag]. If not, the model
# probably refused/echoed something odd — let the caller fall back.
if "[" not in s:
    sys.exit(1)
sys.stdout.write(s)
' <<<"$resp") || emit_original

[ -n "$out" ] || emit_original
printf '%s' "$out"
