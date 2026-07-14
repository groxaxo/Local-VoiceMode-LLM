#!/usr/bin/env bash
# Stable entry point for Local-VoiceMode-LLM.
# The implementation lives in scripts/install.sh so it can be syntax-tested and
# shared by fresh installs, repairs, and diagnostics without duplicating logic.
set -Eeuo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$REPO_DIR/scripts/install.sh" "$@"
