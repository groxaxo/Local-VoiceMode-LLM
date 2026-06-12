#!/usr/bin/env bash
# install.sh — autoinstaller that wires the local CPU voice stack into an
# already-installed Ollama, with no Ollama rebuild.
#
# What it does:
#   1. Verifies the stock `ollama` binary is present (and reachable).
#   2. Installs the CPU speech backends — Parakeet STT (:5093) and Supertonic
#      TTS (:8766) — by delegating to the repo's setup.sh. Skipped automatically
#      if they are already installed and healthy (re-run with --reinstall-backends
#      to force, or --skip-backends to never touch them).
#   3. Installs the `ollama-voice` command onto your PATH.
#   4. Smoke-checks Ollama + both backends and prints how to start talking.
#
# This talks to your existing Ollama over its HTTP API (the same one `ollama run`
# uses), so any model you can `ollama run`, you can `ollama-voice`. Speech is
# CPU-only; no GPU and no source build of Ollama are required.
#
# Usage:
#   bash integrations/ollama/install.sh                 # install (auto-detect everything)
#   bash integrations/ollama/install.sh --yes           # no prompts
#   bash integrations/ollama/install.sh --bindir ~/bin  # choose where the command goes
#   bash integrations/ollama/install.sh --model llama3.2  # ensure a model is present
#   bash integrations/ollama/install.sh --skip-backends # only install the command
#   bash integrations/ollama/install.sh --reinstall-backends
#   bash integrations/ollama/install.sh --uninstall [--backends]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
STT_PROBE="${STT_PROBE:-http://127.0.0.1:5093/}"
TTS_PROBE="${TTS_PROBE:-http://127.0.0.1:8766/}"
TALK_SH_PATH="$HOME/.config/opencode/skills/talk/talk.sh"
ENV_FILE="${OLLAMA_VOICE_ENV:-$HOME/.config/opencode/ollama-voice.env}"
SUPERTONIC_FOUND=""

# --- options -----------------------------------------------------------------
BINDIR=""
ASSUME_YES=0
DO_BACKENDS="auto"   # auto | force | skip
UNINSTALL=0
RM_BACKENDS=0
MODEL="${OLLAMA_VOICE_MODEL:-}"

# --- pretty logging ----------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    B=$'\033[1m'; BLU=$'\033[1;34m'; GRN=$'\033[1;32m'; YLW=$'\033[1;33m'; RED=$'\033[1;31m'; CYN=$'\033[1;36m'; Z=$'\033[0m'
else
    B=""; BLU=""; GRN=""; YLW=""; RED=""; CYN=""; Z=""
fi
info()  { printf "%s[install]%s %s\n" "$BLU" "$Z" "$*"; }
ok()    { printf "%s[install]%s \xE2\x9C\x93 %s\n" "$GRN" "$Z" "$*"; }
warn()  { printf "%s[install]%s %s\n" "$YLW" "$Z" "$*" >&2; }
die()   { printf "%s[install]%s %s\n" "$RED" "$Z" "$*" >&2; exit 1; }

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# --- parse flags -------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y)             ASSUME_YES=1 ;;
        --bindir)             BINDIR="${2:?--bindir needs a path}"; shift ;;
        --bindir=*)           BINDIR="${1#*=}" ;;
        --model)              MODEL="${2:?--model needs a name}"; shift ;;
        --model=*)            MODEL="${1#*=}" ;;
        --skip-backends)      DO_BACKENDS="skip" ;;
        --reinstall-backends) DO_BACKENDS="force" ;;
        --uninstall)          UNINSTALL=1 ;;
        --backends)           RM_BACKENDS=1 ;;
        -h|--help)            usage ;;
        *) warn "unknown flag: $1 (use --help)" ;;
    esac
    shift
done

confirm() {  # confirm "question" -> 0 yes / 1 no  (auto-yes with --yes or non-TTY)
    [ "$ASSUME_YES" = 1 ] && return 0
    [ -t 0 ] || return 0
    printf "%s[install]%s %s [Y/n]: " "$CYN" "$Z" "$1"
    local a; read -r a
    case "${a:-y}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# any HTTP response (even 404) means the server is alive; curl exits non-zero only on no connection
reachable() { curl -s -m 4 -o /dev/null "$1" 2>/dev/null; }

on_path() { case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac; }

pick_bindir() {
    if [ -n "$BINDIR" ]; then printf '%s\n' "$BINDIR"; return; fi
    local local_bin="$HOME/.local/bin"
    if [ -d "$local_bin" ] && [ -w "$local_bin" ] && on_path "$local_bin"; then
        printf '%s\n' "$local_bin"; return
    fi
    if [ -d /usr/local/bin ] && [ -w /usr/local/bin ] && on_path /usr/local/bin; then
        printf '%s\n' /usr/local/bin; return
    fi
    printf '%s\n' "$local_bin"   # default; created + PATH-warned below
}

# POST a tiny synth request; success = HTTP 200 returning WAV (RIFF) audio. This
# positively identifies a Supertonic TTS server and rejects whatever else might
# hold the port (e.g. an unrelated API that 404s or returns JSON).
synth_ok() {
    local url="$1" tmp code
    tmp="$(mktemp)"
    code=$(curl -sS -m 20 -o "$tmp" -w '%{http_code}' "$url/v1/audio/speech" \
        -H 'Content-Type: application/json' \
        -d '{"input":"hi","voice":"F4","response_format":"wav","stream":false,"total_steps":4,"speed":1.0,"lang_code":"en"}' \
        2>/dev/null) || { rm -f "$tmp"; return 1; }
    if [ "$code" = "200" ] && [ "$(head -c 4 "$tmp" 2>/dev/null)" = "RIFF" ]; then
        rm -f "$tmp"; return 0
    fi
    rm -f "$tmp"; return 1
}

# Find a working local TTS and persist it as ollama-voice's defaults, so the
# voice loop prefers local synthesis over the xAI cloud. The project default is
# Supertonic on :8766, but that port is sometimes taken by another service — we
# probe the user's SUPERTONIC_URL, then :8766, then :8765. Honors an existing env.
detect_and_persist_tts() {
    local cands="${SUPERTONIC_URL:-} http://127.0.0.1:8766 http://127.0.0.1:8765" u
    for u in $cands; do
        [ -n "$u" ] || continue
        u="${u%/}"
        if synth_ok "$u"; then SUPERTONIC_FOUND="$u"; break; fi
    done
    mkdir -p "$(dirname "$ENV_FILE")" 2>/dev/null || true
    if [ -n "$SUPERTONIC_FOUND" ]; then
        ok "Local Supertonic TTS synthesizes at $SUPERTONIC_FOUND"
        if printf '%s\n' \
            "# ollama-voice defaults — written by integrations/ollama/install.sh" \
            "# Your shell environment overrides anything here." \
            "TTS_ENGINE=supertonic" \
            "SUPERTONIC_URL=$SUPERTONIC_FOUND" > "$ENV_FILE" 2>/dev/null; then
            ok "Pinned local TTS for ollama-voice -> $ENV_FILE"
        else
            warn "Supertonic found at $SUPERTONIC_FOUND but could not write $ENV_FILE; set SUPERTONIC_URL yourself."
        fi
    elif reachable "http://127.0.0.1:8020/"; then
        warn "Supertonic not reachable on :8766/:8765 — defaulting ollama-voice to local NeuTTS (:8020)."
        printf '%s\n' \
            "# ollama-voice defaults — written by integrations/ollama/install.sh" \
            "TTS_ENGINE=neutts" > "$ENV_FILE" 2>/dev/null || true
    else
        warn "No local TTS (Supertonic :8766/:8765, NeuTTS :8020) detected — talk.sh's own"
        warn "engine chain applies (will use xAI cloud if XAI_API_KEY is set)."
    fi
}

# --- uninstall ---------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
    removed=0
    for d in "$HOME/.local/bin" /usr/local/bin "$BINDIR"; do
        [ -n "$d" ] || continue
        if [ -e "$d/ollama-voice" ]; then
            if rm -f "$d/ollama-voice" 2>/dev/null; then ok "removed $d/ollama-voice"; removed=1
            else warn "could not remove $d/ollama-voice (try: sudo rm -f $d/ollama-voice)"; fi
        fi
    done
    [ "$removed" = 0 ] && info "no installed ollama-voice command found"
    if [ "$RM_BACKENDS" = 1 ]; then
        info "Removing voice backends via setup.sh --uninstall…"
        bash "$REPO_DIR/setup.sh" --uninstall || warn "setup.sh --uninstall reported an error"
    else
        info "Voice backends (Parakeet/Supertonic) left in place. Remove with:"
        info "    bash $REPO_DIR/setup.sh --uninstall"
    fi
    ok "Uninstall complete."
    exit 0
fi

# --- preflight ---------------------------------------------------------------
info "OpenCode Voice ── Ollama autoinstaller"
command -v bash    >/dev/null 2>&1 || die "bash is required"
command -v curl    >/dev/null 2>&1 || die "curl is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required (the runtime command is a Python script)"

if command -v ollama >/dev/null 2>&1; then
    OLLAMA_VER="$(ollama --version 2>/dev/null | head -1 || true)"
    ok "Found Ollama: ${OLLAMA_VER:-$(command -v ollama)}"
else
    warn "The \`ollama\` binary was not found on PATH."
    warn "Install it from https://ollama.com/download (macOS/Windows app) or:"
    warn "    curl -fsSL https://ollama.com/install.sh | sh   # Linux"
    die  "Re-run this installer once Ollama is installed."
fi

if reachable "$OLLAMA_HOST/api/version"; then
    ok "Ollama server is running at $OLLAMA_HOST"
else
    warn "Ollama server not responding at $OLLAMA_HOST — that's fine; \`ollama-voice\` will start it on demand (or run \`ollama serve\`)."
fi

# --- backends (Parakeet STT + Supertonic TTS) --------------------------------
backends_healthy() {
    [ -f "$TALK_SH_PATH" ] && reachable "$STT_PROBE" && reachable "$TTS_PROBE"
}

run_setup() {
    info "Installing CPU voice backends via setup.sh (first run downloads models — this can take a few minutes)…"
    # --no-integrations: install the venv + Parakeet + Supertonic and the canonical
    # talk.sh at ~/.config/opencode/skills/talk/, without copying the skill into
    # other agents. setup.sh runs non-interactively whenever a flag is passed.
    bash "$REPO_DIR/setup.sh" --no-integrations
}

case "$DO_BACKENDS" in
    skip)
        info "Skipping backend install (--skip-backends)."
        ;;
    force)
        run_setup
        ;;
    auto)
        if backends_healthy; then
            ok "Voice backends already installed and reachable (STT :5093, TTS :8766) — skipping setup.sh."
        elif [ -f "$TALK_SH_PATH" ]; then
            warn "talk.sh is installed but a backend isn't responding yet."
            if confirm "Run setup.sh to (re)install/start the voice backends?"; then run_setup
            else info "Leaving backends as-is. \`ollama-voice --status\` will show what's up."; fi
        else
            run_setup
        fi
        ;;
esac

# Resolve the talk.sh the command will use (installed copy, else repo copy).
if [ -f "$TALK_SH_PATH" ]; then
    RESOLVED_TALK="$TALK_SH_PATH"
elif [ -f "$REPO_DIR/service/talk.sh" ]; then
    RESOLVED_TALK="$REPO_DIR/service/talk.sh"
    warn "Using repo talk.sh ($RESOLVED_TALK); run setup.sh to install it to the standard location."
else
    die "talk.sh not found. Run setup.sh, or pass --reinstall-backends."
fi

# --- install the ollama-voice command ----------------------------------------
SRC="$SCRIPT_DIR/ollama-voice"
[ -f "$SRC" ] || die "missing $SRC (run from a full repo checkout)"

DEST_DIR="$(pick_bindir)"
mkdir -p "$DEST_DIR" || die "cannot create $DEST_DIR"
[ -w "$DEST_DIR" ] || die "$DEST_DIR is not writable (choose another with --bindir, or use sudo)"

install -m 0755 "$SRC" "$DEST_DIR/ollama-voice" 2>/dev/null || { cp "$SRC" "$DEST_DIR/ollama-voice" && chmod 0755 "$DEST_DIR/ollama-voice"; }
ok "Installed command: $DEST_DIR/ollama-voice"

if ! on_path "$DEST_DIR"; then
    warn "$DEST_DIR is not on your PATH. Add it, e.g.:"
    warn "    echo 'export PATH=\"$DEST_DIR:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
    RUN_HINT="$DEST_DIR/ollama-voice"
else
    RUN_HINT="ollama-voice"
fi

# --- model -------------------------------------------------------------------
DEFAULT_MODEL=""
if reachable "$OLLAMA_HOST/api/version"; then
    MODELS="$(ollama list 2>/dev/null | awk 'NR>1{print $1}' || true)"
    if [ -n "$MODEL" ]; then
        if printf '%s\n' "$MODELS" | grep -qx "$MODEL" || printf '%s\n' "$MODELS" | grep -qx "$MODEL:latest"; then
            ok "Model present: $MODEL"; DEFAULT_MODEL="$MODEL"
        elif confirm "Model '$MODEL' is not installed. Pull it now?"; then
            ollama pull "$MODEL" && DEFAULT_MODEL="$MODEL"
        fi
    elif [ -n "$MODELS" ]; then
        DEFAULT_MODEL="$(printf '%s\n' "$MODELS" | head -1)"
        ok "Will default to your installed model: $DEFAULT_MODEL"
        info "Installed models:"; printf '%s\n' "$MODELS" | sed 's/^/    /'
    else
        warn "No Ollama models installed."
        if confirm "Pull a small default model (llama3.2) now?"; then
            ollama pull llama3.2 && DEFAULT_MODEL="llama3.2"
        else
            info "Pull one later with:  ollama pull <model>"
        fi
    fi
fi

# --- smoke check (no audio is played) ----------------------------------------
info "── Verification ───────────────────────────────────────────────"
reachable "$OLLAMA_HOST/api/version" && ok "Ollama API reachable ($OLLAMA_HOST)" || warn "Ollama API not reachable (start with: ollama serve)"
reachable "$STT_PROBE" && ok "STT backend reachable (:5093)" || warn "STT backend not reachable (:5093) — check: bash $RESOLVED_TALK status"
detect_and_persist_tts

# --- done --------------------------------------------------------------------
echo ""
ok "Done. Talk to your local model with your voice:"
echo ""
if [ -n "$DEFAULT_MODEL" ]; then
    echo "    ${B}$RUN_HINT${Z}                 # talk to ${B}$DEFAULT_MODEL${Z}"
else
    echo "    ${B}$RUN_HINT${Z} <model>         # e.g. $RUN_HINT llama3.2"
fi
echo "    $RUN_HINT --text          # type instead of speaking (mic-free test)"
echo "    $RUN_HINT --list          # list local models"
echo "    $RUN_HINT --status        # check Ollama + voice backends"
echo ""
if [ -n "$SUPERTONIC_FOUND" ]; then
    echo "  Voice replies use local Supertonic TTS ($SUPERTONIC_FOUND) — pinned in $ENV_FILE."
fi
echo "  Speak after the tone; pause to send your turn; press Ctrl-C to exit."
echo "  Tip: for an \`ollama voice <model>\` feel, add this shell function:"
echo "      ollama(){ [ \"\$1\" = voice ] && { shift; command ollama-voice \"\$@\"; } || command ollama \"\$@\"; }"
echo ""
