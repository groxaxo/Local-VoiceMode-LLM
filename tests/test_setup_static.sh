#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$ROOT/setup.sh"
find "$ROOT/scripts" -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
bash -n "$ROOT/service/doctor.sh"
help_text="$($ROOT/setup.sh --help)"
grep -Fq -- '--mlx' <<< "$help_text"
grep -Fq -- '--onnx' <<< "$help_text"

all_installer="$(cat "$ROOT/scripts/install.sh" "$ROOT"/scripts/install.d/*.sh)"
grep -Fq 'SUPERTONIC_PORT="${SUPERTONIC_PORT:-8766}"' <<< "$all_installer"
grep -Fq 'assets/supertonic-3/onnx' <<< "$all_installer"
grep -Fq 'assets/supertonic-3/voice_styles' <<< "$all_installer"
grep -Fq 'assets/supertonic-3-mlx' <<< "$all_installer"
grep -Fq 'mlx-community/supertonic-3' <<< "$all_installer"
grep -Fq 'py[mlx]' <<< "$all_installer"
grep -Fq 'SUPERTONIC_MLX_FALLBACK_TO_ONNX' <<< "$all_installer"
grep -Fq 'v1/audio/transcriptions' <<< "$all_installer"
grep -Fq 'v1/audio/speech' <<< "$all_installer"
grep -Fq 'Supertonic runtime backend' <<< "$all_installer"

if grep -Eq 'load_launchd_service com\.opencode\.tts-server|launchctl_load_or_kick "com\.opencode\.tts-server"' <<< "$all_installer"; then
  echo "installer must not manage the unrelated legacy Chatterbox launchd job" >&2
  exit 1
fi

python3 - <<PY
import plistlib
from pathlib import Path
root=Path("$ROOT")
for path in (root/'launchd/com.opencode.supertonic.plist', root/'launchd/com.opencode.parakeet-stt.plist'):
    with path.open('rb') as f: plistlib.load(f)
mlx = plistlib.loads((root/'launchd/com.opencode.supertonic.plist').read_bytes())
env = mlx['EnvironmentVariables']
assert env['SUPERTONIC_ORT_BACKEND'] == 'auto'
assert env['SUPERTONIC_MLX_FALLBACK_TO_ONNX'] == 'true'
assert env['SUPERTONIC_MLX_MODEL_DIR'].endswith('assets/supertonic-3-mlx')
PY

echo "setup static checks passed"
