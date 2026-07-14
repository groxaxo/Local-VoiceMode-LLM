# macOS repair and verification

A launchd job being listed does **not** prove that its API is usable. The installer now treats setup as successful only after:

1. Parakeet accepts an OpenAI-compatible transcription request on port `5093`.
2. Supertonic generates a non-empty WAV through `/v1/audio/speech` on port `8766`.
3. The selected launchd definitions load without suppressed errors.

## Repair an earlier installation

```bash
cd Local-VoiceMode-LLM
git pull --ff-only
chmod +x setup.sh
./setup.sh
```

The repair is idempotent. It rewrites an older managed Supertonic plist with the correct model locations:

- `assets/supertonic-3/onnx`
- `assets/supertonic-3/voice_styles`

It preserves an unrelated pre-existing Parakeet-compatible `speech-server` service when that server passes the transcription probe. Use `./setup.sh --force` only when a conflicting or broken service definition must be replaced.

## Diagnose without reinstalling

```bash
./setup.sh --doctor
# or, after installation:
~/.config/opencode/skills/talk/doctor.sh
```

## Ports and service names

| Component | Port | launchd label |
|---|---:|---|
| Parakeet STT | 5093 | `com.opencode.parakeet-stt` |
| Supertonic TTS | 8766 | `com.opencode.supertonic` |
| Legacy Chatterbox, when separately installed | 8765 | `com.opencode.tts-server` |

The installer does not start, stop, or claim ownership of the legacy Chatterbox service. Installed `tts.sh` copies are pinned to the selected Supertonic port so they cannot silently send requests to port `8765`.

## Reading the result

A valid run ends with `Setup verified successfully`. Any dependency, model-download, launchd, STT, or TTS failure exits non-zero and prints the relevant log tail. There is no partial-success message.
