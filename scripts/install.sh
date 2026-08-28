#!/usr/bin/env bash
# Reliable cross-platform installer for Local-VoiceMode-LLM.
# A run is successful only when every selected backend passes a real API test.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

for module in \
  00-config.sh \
  10-common.sh \
  20-probes.sh \
  30-parakeet.sh \
  40-supertonic.sh \
  90-install.sh \
  91-services.sh \
  99-verify.sh; do
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/install.d/$module"
done
