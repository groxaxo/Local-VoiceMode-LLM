#!/bin/bash
# talk skill TTS wrapper — delegates to the shared OpenCode CLI.
exec "$HOME/.config/opencode/tts.sh" "$@"
