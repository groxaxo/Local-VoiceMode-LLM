# Supertonic 2 optional backend

[Supertonic Express 2](https://github.com/groxaxo/supertonic-express) is an optional local ONNX TTS service based on [`onnx-community/Supertonic-TTS-2-ONNX`](https://huggingface.co/onnx-community/Supertonic-TTS-2-ONNX).

It is designed for fast CPU synthesis and supports English, Korean, Spanish, Portuguese, and French. The service exposes an OpenAI-compatible `/v1/audio/speech` endpoint and runs independently from the default Supertonic 3 backend.

| Backend | Default port | Installed by main setup |
|---|---:|---|
| Supertonic 3 | `8766` | yes |
| Supertonic 2 | `8880` | no; install from this directory |

Both can run at the same time.

## Install

From the Local VoiceMode LLM repository root:

```bash
bash integrations/supertonic2/install.sh
```

The installer:

1. Clones or updates `groxaxo/supertonic-express` under `~/.config/opencode/supertonic2-tts`.
2. Creates an isolated Python environment.
3. Downloads the ONNX model unless it is already present or `--skip-model` is used.
4. Registers a user service through systemd on Linux or launchd on macOS.
5. Starts the service and performs a basic health check.

### Installer flags

| Flag | Effect |
|---|---|
| `--yes` / `-y` | Run without prompts |
| `--port 8881` | Use a different service port |
| `--port=8881` | Equivalent inline form |
| `--skip-model` | Skip model download |
| `--uninstall` | Stop the service and remove the installation directory |

Examples:

```bash
bash integrations/supertonic2/install.sh --yes
bash integrations/supertonic2/install.sh --port 8881
```

## Select it in the current dispatcher

The service uses the same request schema as Supertonic 3, but `service/tts.sh` currently does **not** define a separate `TTS_ENGINE=supertonic2` dispatcher case.

Use the existing Supertonic client with the alternate endpoint:

```bash
TTS_ENGINE=supertonic \
SUPERTONIC_URL=http://127.0.0.1:8880 \
TTS_QUALITY=normal \
~/.config/opencode/tts.sh "Hola, soy Supertonic dos."
```

For the talk loop:

```bash
TTS_ENGINE=supertonic \
SUPERTONIC_URL=http://127.0.0.1:8880 \
TTS_QUALITY=normal \
~/.config/opencode/skills/talk/talk.sh speak "Fast local synthesis."
```

To make this endpoint persistent, export the values in the shell or process manager that launches the agent:

```bash
export TTS_ENGINE=supertonic
export SUPERTONIC_URL=http://127.0.0.1:8880
export TTS_QUALITY=normal
```

A `.env` file is not automatically loaded unless your launcher explicitly sources it.

## Endpoint behavior

Default base URL:

```text
http://127.0.0.1:8880
```

Speech endpoint:

```text
POST /v1/audio/speech
```

The current shared Supertonic client sends fields including:

- `input`
- `voice`
- `lang_code`
- `response_format`
- `total_steps`
- `speed`
- `stream`

## Tuning

Because the current dispatcher reuses the Supertonic 3 client, use the shared variable names:

| Variable | Recommended value | Purpose |
|---|---|---|
| `SUPERTONIC_URL` | `http://127.0.0.1:8880` | Select the Supertonic 2 service |
| `SUPERTONIC_VOICE` | `F4` or another supported id | Voice style |
| `TTS_QUALITY` | `normal` | 8-step low-latency preset |
| `SUPERTONIC_STEPS` | unset or `8` | Explicit denoising-step override |
| `SUPERTONIC_SPEED` | `1.0` | Speed multiplier |
| `TTS_FADE_MS` | `6` | Edge fade used to reduce clicks |

The optional installer also accepts `SUPERTONIC2_PORT`, `SUPERTONIC2_DIR`, and `OPENCODE_CONFIG_DIR` while creating the service. Those installer variables do not replace the runtime `SUPERTONIC_URL` used by `tts.sh`.

## Fallback behavior

Pointing `SUPERTONIC_URL` at `:8880` selects that endpoint for the normal `supertonic` dispatcher branch:

```text
selected Supertonic URL → NeuTTS → xAI
```

It does **not** automatically retry Supertonic 3 on `:8766`. To return to Supertonic 3:

```bash
export SUPERTONIC_URL=http://127.0.0.1:8766
```

A dedicated multi-Supertonic fallback alias would require a dispatcher implementation change; the documentation does not claim that behavior today.

## Manage the service

### Linux

```bash
systemctl --user status opencode-supertonic2
systemctl --user restart opencode-supertonic2
journalctl --user -u opencode-supertonic2 -f
```

The installer also writes logs to:

```text
~/.config/opencode/supertonic2.log
```

### macOS

```bash
launchctl print gui/$(id -u)/com.opencode.supertonic2
launchctl kickstart -k gui/$(id -u)/com.opencode.supertonic2
tail -f ~/.config/opencode/supertonic2.log
```

## Verify

Check health:

```bash
curl -fsS http://127.0.0.1:8880/health || \
  curl -fsS http://127.0.0.1:8880/
```

Generate a WAV without playback:

```bash
TTS_ENGINE=supertonic \
SUPERTONIC_URL=http://127.0.0.1:8880 \
TTS_NO_PLAY=1 \
~/.config/opencode/tts.sh "Backend verification"
```

The command should print the path to a non-empty WAV file.

## Uninstall

```bash
bash integrations/supertonic2/install.sh --uninstall
```

This stops/removes its user service and deletes `~/.config/opencode/supertonic2-tts`. It does not remove the default Supertonic 3 backend.
