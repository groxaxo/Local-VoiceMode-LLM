#!/usr/bin/env bash
# Install the optional Supertonic 2 OpenAI-compatible TTS service.
#
# The service runs separately from Supertonic 3. The current Local VoiceMode LLM
# dispatcher selects it through the normal Supertonic client plus an endpoint
# override:
#
#   TTS_ENGINE=supertonic \
#   SUPERTONIC_URL=http://127.0.0.1:8880 \
#   ~/.config/opencode/tts.sh "Hello"
#
# Usage:
#   bash integrations/supertonic2/install.sh
#   bash integrations/supertonic2/install.sh --yes
#   bash integrations/supertonic2/install.sh --port 8881
#   bash integrations/supertonic2/install.sh --skip-model
#   bash integrations/supertonic2/install.sh --uninstall

set -euo pipefail

CONFIG_DIR="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"
INSTALL_DIR="${SUPERTONIC2_DIR:-$CONFIG_DIR/supertonic2-tts}"
VENV_DIR="$INSTALL_DIR/.venv"
ASSETS_DIR="$INSTALL_DIR/assets"
REPO_URL="https://github.com/groxaxo/supertonic-express"
HF_MODEL="onnx-community/Supertonic-TTS-2-ONNX"
PORT="${SUPERTONIC2_PORT:-8880}"
LOG_FILE="$CONFIG_DIR/supertonic2.log"
SERVICE_NAME="opencode-supertonic2"
PLIST_LABEL="com.opencode.supertonic2"

ASSUME_YES=0
SKIP_MODEL=0
UNINSTALL=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    BLUE=$'\033[1;34m'
    GREEN=$'\033[1;32m'
    YELLOW=$'\033[1;33m'
    RED=$'\033[1;31m'
    RESET=$'\033[0m'
else
    BLUE=""
    GREEN=""
    YELLOW=""
    RED=""
    RESET=""
fi

info() { printf '%s[supertonic2]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s[supertonic2]%s ✓ %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[supertonic2]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%s[supertonic2]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Install the optional Supertonic 2 TTS backend.

Options:
  --yes, -y        Run without confirmation prompts
  --port PORT      Listen on PORT (default: 8880)
  --port=PORT      Equivalent inline form
  --skip-model     Do not download the model
  --uninstall      Stop the service and remove the installation directory
  --help, -h       Show this help

Runtime selection after installation:
  TTS_ENGINE=supertonic \
  SUPERTONIC_URL=http://127.0.0.1:8880 \
  ~/.config/opencode/tts.sh "Hello"
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)
            ASSUME_YES=1
            ;;
        --port)
            [[ $# -ge 2 ]] || die "--port requires a value"
            PORT="$2"
            shift
            ;;
        --port=*)
            PORT="${1#--port=}"
            ;;
        --skip-model)
            SKIP_MODEL=1
            ;;
        --uninstall)
            UNINSTALL=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1 (use --help)"
            ;;
    esac
    shift
done

[[ "$PORT" =~ ^[0-9]+$ ]] || die "Port must be numeric: $PORT"
(( PORT >= 1 && PORT <= 65535 )) || die "Port must be between 1 and 65535"

case "$(uname -s 2>/dev/null || true)" in
    Darwin) PLATFORM="macos" ;;
    Linux)  PLATFORM="linux" ;;
    *)      die "This installer supports macOS and Linux. Use the Windows project setup for Windows." ;;
esac

command_exists() { command -v "$1" >/dev/null 2>&1; }
require_command() {
    command_exists "$1" || die "$1 is required but was not found on PATH"
}

remove_service() {
    if [[ "$PLATFORM" == "linux" ]]; then
        local unit="$HOME/.config/systemd/user/$SERVICE_NAME.service"
        if command_exists systemctl; then
            systemctl --user disable --now "$SERVICE_NAME.service" >/dev/null 2>&1 || true
            systemctl --user daemon-reload >/dev/null 2>&1 || true
        fi
        rm -f "$unit"
    else
        local plist="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
        launchctl bootout "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1 \
            || launchctl unload "$plist" >/dev/null 2>&1 \
            || true
        rm -f "$plist"
    fi
}

if [[ "$UNINSTALL" -eq 1 ]]; then
    info "Stopping and removing the Supertonic 2 service"
    remove_service
    rm -rf "$INSTALL_DIR"
    ok "Removed $INSTALL_DIR"
    info "Supertonic 3 and the main Local VoiceMode LLM installation were not removed."
    exit 0
fi

require_command git
require_command python3
require_command curl

if [[ "$ASSUME_YES" -ne 1 && -t 0 ]]; then
    printf 'Install Supertonic 2 to %s and run it on port %s? [Y/n]: ' "$INSTALL_DIR" "$PORT"
    read -r answer
    case "${answer:-Y}" in
        Y|y|YES|Yes|yes) ;;
        *) info "Cancelled"; exit 0 ;;
    esac
fi

mkdir -p "$CONFIG_DIR"

if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Updating existing checkout at $INSTALL_DIR"
    git -C "$INSTALL_DIR" pull --ff-only
else
    info "Cloning Supertonic Express 2 into $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
fi

REQUIREMENTS="$INSTALL_DIR/py/requirements.txt"
[[ -f "$REQUIREMENTS" ]] || die "Unexpected repository layout: $REQUIREMENTS is missing"

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    info "Creating Python environment"
    python3 -m venv "$VENV_DIR" \
        || die "Could not create the virtual environment. Install the Python venv package and retry."
fi

PYTHON="$VENV_DIR/bin/python"
info "Installing Python dependencies"
"$PYTHON" -m pip install --quiet --upgrade pip setuptools wheel
"$PYTHON" -m pip install --quiet -r "$REQUIREMENTS"
"$PYTHON" -m pip install --quiet huggingface-hub transformers
ok "Dependencies installed"

MODEL_SENTINEL="$ASSETS_DIR/onnx/voice_decoder.onnx"
if [[ "$SKIP_MODEL" -eq 1 ]]; then
    warn "Skipping model download; the service will fail until compatible assets exist at $ASSETS_DIR"
elif [[ -s "$MODEL_SENTINEL" ]]; then
    ok "Model assets already exist at $ASSETS_DIR"
else
    info "Downloading $HF_MODEL into $ASSETS_DIR"
    "$PYTHON" - "$HF_MODEL" "$ASSETS_DIR" <<'PY'
from pathlib import Path
import sys

from huggingface_hub import snapshot_download

model_id, destination = sys.argv[1], Path(sys.argv[2])
destination.mkdir(parents=True, exist_ok=True)
snapshot_download(model_id, local_dir=str(destination))
PY
    [[ -s "$MODEL_SENTINEL" ]] || die "Model download completed without the expected file: $MODEL_SENTINEL"
    ok "Model assets ready"
fi

write_systemd_service() {
    local systemd_dir="$HOME/.config/systemd/user"
    local unit="$systemd_dir/$SERVICE_NAME.service"
    mkdir -p "$systemd_dir"

    cat > "$unit" <<EOF
[Unit]
Description=Supertonic 2 TTS server on port $PORT
After=network.target

[Service]
Type=simple
ExecStart=$PYTHON -m uvicorn api.src.main:app --host 127.0.0.1 --port $PORT --app-dir $INSTALL_DIR/py
WorkingDirectory=$INSTALL_DIR/py
Restart=on-failure
RestartSec=5
Environment=HOME=$HOME
Environment=ONNX_DIR=$ASSETS_DIR
Environment=VOICE_STYLES_DIR=$ASSETS_DIR
Environment=USE_GPU=false
Environment=SUPERTONIC_ORT_BACKEND=cpu
Environment=PORT=$PORT
Environment=LOG_LEVEL=INFO
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=default.target
EOF

    if command_exists systemctl && systemctl --user show-environment >/dev/null 2>&1; then
        systemctl --user daemon-reload
        systemctl --user enable --now "$SERVICE_NAME.service"
        ok "Started $SERVICE_NAME.service"
    else
        warn "systemctl --user is unavailable. The unit was written to $unit"
        warn "Start it from a user systemd session with:"
        warn "  systemctl --user daemon-reload && systemctl --user enable --now $SERVICE_NAME.service"
    fi
}

write_launchd_service() {
    local launch_agents="$HOME/Library/LaunchAgents"
    local plist="$launch_agents/$PLIST_LABEL.plist"
    mkdir -p "$launch_agents"

    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$PLIST_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PYTHON</string>
    <string>-m</string>
    <string>uvicorn</string>
    <string>api.src.main:app</string>
    <string>--host</string>
    <string>127.0.0.1</string>
    <string>--port</string>
    <string>$PORT</string>
    <string>--app-dir</string>
    <string>$INSTALL_DIR/py</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>$VENV_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>ONNX_DIR</key>
    <string>$ASSETS_DIR</string>
    <key>VOICE_STYLES_DIR</key>
    <string>$ASSETS_DIR</string>
    <key>USE_GPU</key>
    <string>false</string>
    <key>SUPERTONIC_ORT_BACKEND</key>
    <string>cpu</string>
    <key>PORT</key>
    <string>$PORT</string>
    <key>LOG_LEVEL</key>
    <string>INFO</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>$INSTALL_DIR/py</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>$LOG_FILE</string>
  <key>StandardErrorPath</key>
  <string>$LOG_FILE</string>
</dict>
</plist>
EOF

    launchctl bootout "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$plist" \
        || launchctl load "$plist" \
        || die "Could not load $plist. Inspect it and the launchd logs."
    ok "Loaded $PLIST_LABEL"
}

if [[ "$PLATFORM" == "linux" ]]; then
    write_systemd_service
else
    write_launchd_service
fi

URL="http://127.0.0.1:$PORT"
info "Waiting for the service at $URL"
service_ready=0
for _ in $(seq 1 45); do
    if curl -fsS --max-time 2 "$URL/health" >/dev/null 2>&1 \
        || curl -fsS --max-time 2 "$URL/" >/dev/null 2>&1; then
        service_ready=1
        break
    fi
    sleep 1
done

if [[ "$service_ready" -eq 1 ]]; then
    ok "Supertonic 2 is reachable at $URL"
else
    warn "The service is not reachable yet. First model initialization can be slow."
    warn "Inspect $LOG_FILE and the platform service status."
fi

cat <<EOF

Supertonic 2 installation complete.

Use it with the current dispatcher:

  TTS_ENGINE=supertonic \\
  SUPERTONIC_URL=$URL \\
  TTS_QUALITY=normal \\
  $CONFIG_DIR/tts.sh "Hello from Supertonic two."

To return to the managed Supertonic 3 service, use:

  SUPERTONIC_URL=http://127.0.0.1:8766

Documentation:
  integrations/supertonic2/README.md
EOF
