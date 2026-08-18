# Docker deployment

Local VoiceMode LLM provides two intentionally separate container targets:

1. **Dashboard** — a small, cross-platform image that proxies status, STT, and TTS requests to services on the host or network.
2. **Linux audio** — a larger image with Silero VAD, PortAudio, CPU PyTorch, ONNX Runtime, ALSA/Pulse tools, ffmpeg, and direct `/dev/snd` access.

Native installation remains recommended for macOS and Windows microphone use because Docker Desktop does not expose CoreAudio or Windows audio with native-process semantics.

## Mandatory sentence tagging

Every xAI request made by the Unix runtime must prove:

```json
{
  "sentence_count": 2,
  "tagged_sentence_count": 2,
  "untagged_sentence_indexes": []
}
```

The audio target uses the same `service/tts.sh` safety wrapper and `service/xai_sentence_tagger.py` as native Unix installation. The optional AI Sentence Tagger / AI Voice Studio bridge also refuses returned audio unless its companion supplies complete N/N annotation proof.

See [Mandatory xAI sentence tagging](xai-sentence-tagging.md).

## Public source

The canonical repository is public:

```bash
git clone https://github.com/groxaxo/Local-VoiceMode-LLM.git
cd Local-VoiceMode-LLM
```

Build the public Git context directly:

```bash
docker buildx build \
  --load \
  --target dashboard \
  --tag local-voicemode-dashboard:local \
  https://github.com/groxaxo/Local-VoiceMode-LLM.git#main
```

## Private fork or internal mirror

GitHub CLI:

```bash
gh auth login
gh repo clone OWNER/PRIVATE-VOICE-REPO
cd PRIVATE-VOICE-REPO
```

SSH:

```bash
git clone git@github.com:OWNER/PRIVATE-VOICE-REPO.git
cd PRIVATE-VOICE-REPO
```

Private BuildKit context through SSH:

```bash
ssh-add -l
docker buildx build \
  --load \
  --ssh default \
  --target dashboard \
  --tag local-voicemode-dashboard:private \
  git@github.com:OWNER/PRIVATE-VOICE-REPO.git#main
```

Token preflight authentication:

```bash
export GIT_AUTH_TOKEN='your-short-lived-token'
docker buildx build \
  --load \
  --secret id=GIT_AUTH_TOKEN \
  --target dashboard \
  --tag local-voicemode-dashboard:private \
  https://github.com/OWNER/PRIVATE-VOICE-REPO.git#main
unset GIT_AUTH_TOKEN
```

Do not put GitHub tokens in clone URLs, Dockerfiles, Compose files, image labels, environment defaults, or build arguments.

## Dashboard mode

The dashboard container does not run Parakeet or Supertonic. It connects to existing endpoints:

```bash
docker compose up -d --build dashboard
```

Open `http://127.0.0.1:7862`.

Defaults from inside the container:

```text
Supertonic -> http://host.docker.internal:8766
Parakeet   -> http://host.docker.internal:5093
```

Override them:

```bash
DOCKER_SUPERTONIC_URL=http://192.168.1.50:8766 \
DOCKER_PARAKEET_URL=http://192.168.1.50:5093 \
docker compose up -d
```

The dashboard uses:

- loopback binding by default;
- non-root UID/GID `10001` by default;
- a read-only root filesystem;
- writable `/tmp`, config, and model-cache mounts;
- all Linux capabilities dropped;
- `no-new-privileges`;
- a health check on `/`.

The dashboard's `systemd --user` controls are host-management features and cannot restart host services from an isolated container. Status and proxy tests remain useful; manage host services on the host.

Standalone build:

```bash
docker build \
  --target dashboard \
  --build-arg APP_VERSION=local \
  --build-arg VCS_REF="$(git rev-parse HEAD)" \
  -t local-voicemode-dashboard:local .
```

Standalone run:

```bash
docker run --rm \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=256m \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --add-host host.docker.internal:host-gateway \
  -e SUPERTONIC_URL=http://host.docker.internal:8766 \
  -e PARAKEET_URL=http://host.docker.internal:5093 \
  -p 127.0.0.1:7862:7862 \
  local-voicemode-dashboard:local
```

## Linux audio mode

Requirements:

- Linux host;
- `/dev/snd`;
- working ALSA access, or an explicitly configured PulseAudio/PipeWire socket;
- local or network Parakeet and TTS endpoints;
- enough disk for CPU PyTorch and VAD dependencies.

Use the shared default container identity. Resolve only the host audio-group GID:

```bash
cp .env.example .env
chmod 600 .env
export AUDIO_GID="$(getent group audio | cut -d: -f3)"
```

Start the audio profile:

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.audio.yml \
  --profile audio \
  up -d --build audio
```

Inspect devices:

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.audio.yml \
  exec audio bash /app/service/talk.sh devices
```

Listen once:

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.audio.yml \
  exec audio bash /app/service/talk.sh listen
```

Speak without reopening the microphone:

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.audio.yml \
  exec -e TALK_AUTO_LISTEN=0 audio \
  bash /app/service/talk.sh speak 'The build completed successfully.'
```

The audio profile uses host networking, so `127.0.0.1:5093`, `:8766`, and `:8000` refer to services on the Linux host.

### Shared-volume identity

Dashboard and audio containers share configuration and model-cache volumes. Keep `APP_UID` and `APP_GID` identical for both targets. The supplied default is `10001:10001`.

Override the identity only when a host bind mount or user-owned Pulse/PipeWire socket requires it, and rebuild every target that uses the shared volumes:

```bash
export APP_UID="$(id -u)"
export APP_GID="$(id -g)"
docker compose build --no-cache dashboard
docker compose -f docker-compose.yml -f docker-compose.audio.yml --profile audio build --no-cache audio
```

### PulseAudio or PipeWire

The supplied profile guarantees `/dev/snd` passthrough only. Add a local override for a user socket:

```yaml
services:
  audio:
    environment:
      PULSE_SERVER: unix:/run/user/1000/pulse/native
    volumes:
      - /run/user/1000/pulse/native:/run/user/1000/pulse/native
```

Use the actual host UID and socket path. Do not expose an unauthenticated PulseAudio TCP listener merely to make a container work.

## Fully private/local operation

A fully local layout keeps microphone audio, transcription, and synthesis on the host:

```text
container or native VAD
    -> local Parakeet
    -> local agent/LLM
    -> local Supertonic/Qwen/NeuTTS
    -> local playback
```

Recommended environment:

```env
STT_ENGINE=local
STT_URL=http://127.0.0.1:5093/v1/audio/transcriptions
STT_MODEL=parakeet-tdt-0.6b-v3
TTS_ENGINE=supertonic
SUPERTONIC_URL=http://127.0.0.1:8766
TTS_QUALITY=normal
```

Do not configure hosted-provider keys in this mode.

## Hybrid or non-private provider operation

Hosted STT sends recorded audio to the selected endpoint. Hosted TTS sends reply text. The xAI/Google companion bridge sends directed text to the provider configured by AI Sentence Tagger or AI Voice Studio.

Container bridge example:

```env
TTS_SH=/app/integrations/ai-sentence-tagger/tts-provider.sh
AI_TTS_URL=http://127.0.0.1:8000
AI_TTS_PROVIDER=google
AI_TTS_VOICE=Kore
```

The bridge accepts audio only after verifying:

- `tagged_sentence_count == sentence_count`;
- `untagged_sentence_indexes == []`;
- one unique annotation row per sentence; and
- every row contains inserted direction.

## Network exposure

The default dashboard bind is private:

```text
127.0.0.1:7862
```

For LAN, VPN, or an authenticated reverse proxy:

```bash
BIND_ADDRESS=0.0.0.0 docker compose up -d
```

Do not expose the dashboard directly to the public internet. Put TLS, authentication, firewall rules, and request limits in front. Treat it as an operator interface because it proxies text and audio to configured backends.

## Compose settings

| Variable | Default | Purpose |
|---|---:|---|
| `BIND_ADDRESS` | `127.0.0.1` | Dashboard host bind |
| `DASHBOARD_PORT` | `7862` | Dashboard host port |
| `DOCKER_SUPERTONIC_URL` | `http://host.docker.internal:8766` | Dashboard proxy target |
| `DOCKER_PARAKEET_URL` | `http://host.docker.internal:5093` | Dashboard proxy target |
| `VOICEMODE_CONFIG_VOLUME` | `local-voicemode-config` | Persistent configuration volume |
| `VOICEMODE_CACHE_VOLUME` | `local-voicemode-cache` | Persistent model/cache volume |
| `APP_UID` / `APP_GID` | `10001` | Shared container identity |
| `AUDIO_GID` | `29` | Supplemental host audio group |
| `APP_VERSION` | `dev` | OCI image label |
| `VCS_REF` | `unknown` | OCI revision label |

## Validation

```bash
docker compose config
docker compose -f docker-compose.yml -f docker-compose.audio.yml --profile audio config
docker build --target dashboard -t local-voicemode-dashboard:test .
# Optional large build:
docker build --target audio -t local-voicemode-audio:test .

python -m compileall -q service frontend integrations tests
bash -n service/talk.sh service/tts.sh service/tts_backends.sh
python -m unittest tests.test_xai_sentence_tagger -v
python -m unittest tests.test_tts_wrapper -v
python -m unittest tests.test_ai_tts_provider -v
```

Physical microphone, speaker, host service-manager, large model download, and paid-provider checks remain host-specific.

## Cleanup

Stop containers without deleting configuration or cache volumes:

```bash
docker compose down
```

Delete named volumes only when a permanent reset is intended:

```bash
docker compose down -v
```

Transient recordings live in the audio container's tmpfs `/tmp` and disappear with the container.
