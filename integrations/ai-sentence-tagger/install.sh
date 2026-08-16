#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${AI_TTS_INSTALL_DIR:-$HOME/.config/opencode/ai-tts-provider}"

mkdir -p "$TARGET_DIR"
install -m 0755 "$SCRIPT_DIR/tts_provider.py" "$TARGET_DIR/tts_provider.py"
install -m 0755 "$SCRIPT_DIR/tts-provider.sh" "$TARGET_DIR/tts-provider.sh"

cat <<EOF
Installed the AI Sentence Tagger / AI Voice Studio bridge:

  $TARGET_DIR/tts-provider.sh

Configure the companion service, then export:

  export TTS_SH="$TARGET_DIR/tts-provider.sh"
  export AI_TTS_URL="http://127.0.0.1:8000"
  export AI_TTS_PROVIDER="google"   # or xai
  export AI_TTS_VOICE="Kore"       # or eve for xAI

Verify catalogs:

  python3 "$TARGET_DIR/tts_provider.py" providers
  python3 "$TARGET_DIR/tts_provider.py" voices --provider google
EOF
