# tts_lang.sh — shared language detection (source, do not execute)

# Resolve BCP-47-ish lang code: explicit arg > text heuristic
resolve_lang() {
    local explicit="${1:-}"
    local text="${2:-}"
    if [ -n "$explicit" ]; then
        printf '%s' "$explicit" | tr '[:upper:]' '[:lower:]' | cut -d- -f1
        return
    fi
    detect_lang "$text"
}

# NeuTTS voice defaults (remote .54 / remote full-safetensors server)
neutts_voice_for_lang() {
    local lang
    lang="$(printf '%s' "${1:-en}" | tr '[:upper:]' '[:lower:]' | cut -d- -f1)"
    case "$lang" in
        es) echo "lucia" ;;
        en) echo "jo" ;;
        *) echo "jo" ;;
    esac
}

# Explicit NEUTTS_VOICE wins; otherwise map language → voice preset.
resolve_neutts_voice() {
    local lang="$1"
    if [ -n "${NEUTTS_VOICE:-}" ]; then
        echo "$NEUTTS_VOICE"
        return
    fi
    neutts_voice_for_lang "$lang"
}

# Spanish if accented chars, ¿¡, or common Spanish words (unaccented text included)
detect_lang() {
    local text="$1"
    # Accents and Spanish-only punctuation are decisive on their own.
    if printf '%s' "$text" | grep -qE '[áéíóúñü¿¡ÁÉÍÓÚÑÜ]'; then
        echo "es"
        return
    fi
    # Function-word scoring: a hand-picked keyword list mislabels ordinary
    # unaccented Spanish ("frase de prueba, para que...") as English.
    local helper="${LANG_DETECT_PY:-$HOME/.config/opencode/lang_detect.py}"
    if [ -f "$helper" ]; then
        local guess
        guess="$(python3 "$helper" "$text" 2>/dev/null | tr -d '[:space:]')"
        case "$guess" in
            es|en) echo "$guess"; return ;;
        esac
    fi
    # Expanded Spanish word list: common verbs, pronouns, articles, conjunctions.
    # Whole-word matching (\b on both sides of the group) so English words that
    # merely START with a listed token ("check" → che, "since" → sin) do not
    # false-positive the detection into Spanish.
    if echo "$text" | LC_ALL=C grep -qiE \
        '\b(hola|gracias|maravilloso|senor|senora|buenos|buenas|tardes|noches|por[[:space:]]favor|porque|decime|dime|tenes|tienes|podes|puedes|podrias|podrías|habla|hablar|espanol|español|amigo|amiga|adios|adiós|entiendo|fallo|falló|utilizaste|utilizo|utilizó|voz|trucha|sistema|recursos|momento|verificar|sucedido|que[[:space:]]tal|como[[:space:]]estas|bien|mal|nada|algo|muy|menos|donde|cuando|quien|cual|pero|tambien|siempre|nunca|desde|hasta|conmigo|contigo|nosotros|ellos|ellas|usted|ustedes|vosotros|che|boludo|dale|listo|claro|obvio|genial|barbaro|tranquilo|espera|parame|escuchame|mirá|mira|fijate|bueno|bue)\b'; then
        echo "es"
        return
    fi
    echo "en"
}

# VibeVoice bundled presets (prefix = language family)
vibevoice_voice_for_lang() {
    local lang
    lang="$(printf '%s' "${1:-en}" | tr '[:upper:]' '[:lower:]' | cut -d- -f1)"
    case "$lang" in
        es) echo "sp-Spk0_woman" ;;
        en) echo "en-Emma_woman" ;;
        pt) echo "pt-Spk0_woman" ;;
        fr) echo "fr-Spk1_woman" ;;
        de) echo "de-Spk1_woman" ;;
        it) echo "it-Spk0_woman" ;;
        nl) echo "nl-Spk0_woman" ;;
        pl) echo "pl-Spk0_woman" ;;
        *) echo "en-Emma_woman" ;;
    esac
}

# Pick voice: explicit VIBEVOICE_VOICE wins unless AUTO=1; AUTO maps lang → preset
resolve_vibevoice_voice() {
    local lang="$1"
    if [ "${VIBEVOICE_VOICE_AUTO:-1}" = "1" ]; then
        vibevoice_voice_for_lang "$lang"
        return
    fi
    if [ -n "${VIBEVOICE_VOICE:-}" ]; then
        echo "$VIBEVOICE_VOICE"
        return
    fi
    vibevoice_voice_for_lang "$lang"
}
