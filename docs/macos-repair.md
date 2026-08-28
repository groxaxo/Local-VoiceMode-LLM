# macOS Apple Silicon setup, repair, and verification

A launchd job being listed does **not** prove that its API is usable. The installer treats setup as successful only after:

1. Parakeet accepts an OpenAI-compatible transcription request on port `5093`.
2. Supertonic generates a non-empty WAV through `/v1/audio/speech` on port `8766`.
3. Supertonic `/health` reports the runtime backend that actually generated the audio.
4. The selected launchd definitions load without suppressed errors.

## Default Apple Silicon behavior

On an M1 or newer Mac, a normal installation uses:

- **Primary TTS:** Supertonic 3 through native MLX/Metal
- **Fallback TTS:** Supertonic 3 ONNX Runtime on CPU
- **API port:** `8766`
- **launchd label:** `com.opencode.supertonic`

The installer downloads both model formats. This is intentional: MLX is the preferred path, while the verified ONNX model remains available if MLX cannot initialize after a macOS, python, or MLX package change.

Backend controls:

```bash
./setup.sh             # Apple Silicon: MLX first, ONNX fallback
./setup.sh --mlx       # strict MLX; fail instead of falling back
./setup.sh --onnx      # force only Supertonic to ONNX CPU
./setup.sh --cpu       # force the whole voice stack to CPU/ONNX
```

## Repair or upgrade an earlier installation

```bash
cd /Users/op/Downloads/Local-VoiceMode-LLM/Local-VoiceMode-LLM
git pull --ff-only
chmod +x setup.sh
./setup.sh --integrations=openclaw,hermes
```

A normal successful Apple Silicon run should include:

```text
Supertonic MLX model assets verified
Supertonic runtime backend: mlx (Apple Silicon default)
Setup verified successfully
```

If MLX cannot initialize but ONNX works, setup remains successful and clearly prints:

```text
Supertonic MLX could not initialize; verified ONNX CPU fallback is active
```

Use strict mode to diagnose MLX itself without allowing fallback:

```bash
./setup.sh --mlx --skip-parakeet --no-integrations
```

## Verify the installed runtime

Run the built-in doctor:

```bash
./setup.sh --doctor
# or after installation:
~/.config/opencode/skills/talk/doctor.sh
```

Inspect the API directly:

```bash
curl -s http://127.0.0.1:8766/health | python3 -m json.tool
```

After at least one synthesis request, expect:

```json
{
  "status": "healthy",
  "model_loaded": true,
  "backend": "mlx"
}
```

Generate and play a real WAV:

```bash
curl -fS http://127.0.0.1:8766/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "supertonic",
    "input": "Hello. Supertonic is running through MLX on this Mac.",
    "voice": "F3",
    "response_format": "wav",
    "stream": false,
    "total_steps": 8
  }' \
  -o /tmp/supertonic-mlx-test.wav

file /tmp/supertonic-mlx-test.wav
afplay /tmp/supertonic-mlx-test.wav
curl -s http://127.0.0.1:8766/health | python3 -m json.tool
```

Test the installed skill without automatically reopening the microphone:

```bash
TALK_AUTO_LISTEN=0 TTS_ENGINE=supertonic \
  ~/.config/opencode/skills/talk/talk.sh speak \
  "The Apple Silicon voice test completed successfully."
```

Then test the full microphone-to-STT flow:

```bash
~/.config/opencode/skills/talk/talk.sh devices
~/.config/opencode/skills/talk/talk.sh listen
```

## Compare MLX and ONNX on the same Mac

Run strict MLX and time three warm requests:

```bash
./setup.sh --mlx --skip-parakeet --no-integrations
for n in 1 2 3; do
  /usr/bin/time -p curl -fsS http://127.0.0.1:8766/v1/audio/speech \
    -H 'Content-Type: application/json' \
    -d '{"model":"supertonic","input":"This is a repeatable Supertonic benchmark sentence.","voice":"F3","response_format":"wav","stream":false,"total_steps":8}' \
    -o "/tmp/mlx-${n}.wav"
done
```

Switch to ONNX CPU and repeat:

```bash
./setup.sh --onnx --skip-parakeet --no-integrations
for n in 1 2 3; do
  /usr/bin/time -p curl -fsS http://127.0.0.1:8766/v1/audio/speech \
    -H 'Content-Type: application/json' \
    -d '{"model":"supertonic","input":"This is a repeatable Supertonic benchmark sentence.","voice":"F3","response_format":"wav","stream":false,"total_steps":8}' \
    -o "/tmp/onnx-${n}.wav"
done
```

Restore the recommended MLX-first policy:

```bash
./setup.sh --skip-parakeet --no-integrations
```

## Logs and launchd inspection

```bash
launchctl print gui/$(id -u)/com.opencode.supertonic
tail -n 100 ~/.config/opencode/supertonic.log

grep -A2 -E 'SUPERTONIC_(ORT_BACKEND|MLX_MODEL_DIR|MLX_FALLBACK)' \
  ~/Library/LaunchAgents/com.opencode.supertonic.plist
```

Relevant model directories:

- MLX: `~/.config/opencode/supertonic-tts/assets/supertonic-3-mlx`
- ONNX fallback: `~/.config/opencode/supertonic-tts/assets/supertonic-3`

## Ports and service names

| Component | Port | launchd label |
|---|---:|---|
| Parakeet STT | 5093 | `com.opencode.parakeet-stt` |
| Supertonic TTS | 8766 | `com.opencode.supertonic` |
| Legacy Chatterbox, when separately installed | 8765 | `com.opencode.tts-server` |

The installer does not start, stop, or claim ownership of the legacy Chatterbox service. Installed `tts.sh` copies are pinned to port `8766`.

A valid run ends with `Setup verified successfully`. Any dependency, model-download, launchd, STT, or TTS failure exits non-zero and prints the relevant log tail.
