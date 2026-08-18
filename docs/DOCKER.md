# Docker deployment

Local VoiceMode LLM supports two intentionally separate container modes:

1. **Dashboard mode** — small, cross-platform, and safe for Docker Desktop. It proxies health, STT, and TTS requests to services running on the host or another machine.
2. **Linux audio mode** — a larger image with Silero VAD, PortAudio, CPU PyTorch, ONNX Runtime, audio tools, and direct `/dev/snd` access.

Native installation remains the recommended path for macOS and Windows microphone use because Docker Desktop does not expose host audio devices with the same semantics as native CoreAudio or Windows audio.

## Sentence-tagging guarantee

Every xAI request made by the Unix runtime must prove that every segmented sentence has at least one valid xAI tag:

```json
{
  "sentence_count": 2,
  "tagged_sentence_count": 2,
  "untagged_sentence_indexes": []
}
```

The Docker audio image uses the same `service/tts.sh` safety wrapper and `service/xai_sentence_tagger.py` helper as native Unix installation. The companion-service bridge also rejects returned audio unless the remote AI Sentence Tagger or AI Voice Studio supplies complete N/N annotation proof.

See [Mandatory xAI sentence tagging](xai-sentence-tagging.md).

## Source installation modes

### Public repository

The canonical Local VoiceMode repository is public:

```bash
git clone https://github.com/groxaxo/Local-VoiceMode-LLM.git
cd Local-VoiceMode-LLM
```

A public Git context can be built directly:

```bash
docker buildx build \
  --target dashboard \
  --tag local-voicemode-dashboard:local \
  https://github.com/groxaxo/Local-VoiceMode-LLM.git#main
```

### Private fork or internal mirror

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

Build directly from a private Git context with SSH-agent forwarding:

```bash
ssh-add -l
docker buildx build \
  --ssh default \
  --target dashboard \
  --tag local-voicemode-dashboard:private \
  git@github.com:OWNER/PRIVATE-VOICE-REPO.git#main
```

Token-based BuildKit preflight authentication:

```bash
export GIT_AUTH_TOKEN='your-short-lived-token'
docker buildx build \
  --secret id=GIT_AUTH_TOKEN \
  --target dashboard \
  --tag local-voicemode-dashboard:private \
  https://github.com/OWNER/PRIVATE-VOICE-REPO.git#main
unset GIT_AUTH_TOKEN
```

Do not put GitHub tokens in clone URLs, Dockerfiles, Compose files, image labels, environment defaults, or build arguments.

## Dashboard mode

The dashboard container does not run Parakeet or Supertonic itself. It connects to existing endpoints on the host or network.

```bash
docker compose up -d --build dashboard
```

Open:

```text
http://127.0.0.1:7862
```

Default endpoint mapping from inside the container:

```text
Supertonic -> http://host.docker.internal:8766
Parakeet   -> http://host.docker.internal:5093
```

Override them without changing the normal host shell variables:

```bash
DOCKER_SUPERTONIC_URL=http://192.168.1.50:8766 \
DOCKER_PARAKEET_URL=http://192.168.1.50:5093 \
docker compose up -d
```

The dashboard is loopback-bound by default. It uses:

- non-root UID/GID `10001` by default;
- a read-only root filesystem;
- a temporary writable `/tmp`;
- all Linux capabilities dropped;
- `no-new-privileges`;
- a persistent configuration volume;
- a health check on `/`.

The dashboard's Linux `systemd --user` restart controls are host-management features and do not restart host services from inside an isolated container. Status and proxy tests remain useful; manage host services through the host's native service manager.

### Build only the dashboard target

```bash
docker build \
  --target dashboard \
  --build-arg APP_VERSION=local \
  --build-arg VCS_REF="$(git rev-parse HEAD)" \
  -t local-voicemode-dashboard:local .
```

Run it directly:

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

- Linux host
- `/dev/snd`
- working ALSA device access, or an explicitly configured PulseAudio/PipeWire path
- local or network Parakeet and TTS endpoints
- enough disk space for CPU PyTorch and VAD dependencies

Set host identity and audio group IDs:

```bash
export APP_UID="$(id -u)"
export APP_GID="$(id -g)"
export AUDIO_GID="$(getent group audio | cut -d: -f3)"
```

Create `.env` from the example and configure only the values needed:

```bash
cp .env.example .env
chmod 600 .env
```

Build and start the profile:

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.audio.yml \
  --profile audio \
  up -d --build audio
```

Inspect audio devices:

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

Because the audio profile uses host networking, default endpoints such as `127.0.0.1:5093` and `127.0.0.1:8766` refer to services on the Linux host.

### PulseAudio or PipeWire

The supplied audio profile guarantees `/dev/snd` passthrough only. Hosts that require a PulseAudio or PipeWire socket should add a local Compose override rather than hard-coding one user's runtime path in the repository:

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

Hosted STT/TTS sends audio or reply text to the selected provider. The xAI and Google companion bridge sends the directed transcript to the provider configured by AI Sentence Tagger or AI Voice Studio.

Example companion route:

```env
TTS_SH=/app/integrations/ai-sentence-tagger/tts-provider.sh
AI_TTS_URL=http://127.0.0.1:8000
AI_TTS_PROVIDER=google
AI_TTS_VOICE=Kore
```

When using the audio container with host networking, a companion bound to host port 8000 is reachable at `127.0.0.1:8000`.

The bridge requests full annotations and accepts audio only after verifying:

- `tagged_sentence_count == sentence_count`;
- `untagged_sentence_indexes == []`;
- one unique annotation row per sentence; and
- every row contains inserted direction.

## Private versus public network exposure

The default dashboard bind is private:

```text
127.0.0.1:7862
```

For LAN, VPN, or reverse-proxy access, set an explicit bind:

```bash
BIND_ADDRESS=0.0.0.0 docker compose up -d
```

Do not expose the dashboard directly to the public internet. Put authentication, TLS, firewall rules, and request limits in front. The dashboard can proxy text and audio to configured backends and should be treated as an authenticated operator interface.

## Compose configuration

Useful variables:

| Variable | Default | Purpose |
|---|---:|---|
| `BIND_ADDRESS` | `127.0.0.1` | Dashboard host bind |
| `DASHBOARD_PORT` | `7862` | Dashboard host port |
| `DOCKER_SUPERTONIC_URL` | `http://host.docker.internal:8766` | Dashboard proxy target |
| `DOCKER_PARAKEET_URL` | `http://host.docker.internal:5093` | Dashboard proxy target |
| `VOICEMODE_CONFIG_VOLUME` | `local-voicemode-config` | Persistent dashboard/config volume |
| `APP_UID` | `10001` dashboard; `1000` audio | Container user ID |
| `APP_GID` | `10001` dashboard; `1000` audio | Container primary group |
| `AUDIO_GID` | `29` | Supplemental host audio group |
| `APP_VERSION` | `dev` | OCI image label |
| `VCS_REF` | `unknown` | OCI revision label |

## Validation

Render the Compose configurations:

```bash
docker compose config
docker compose -f docker-compose.yml -f docker-compose.audio.yml --profile audio config
```

Build the small target:

```bash
docker build --target dashboard -t local-voicemode-dashboard:test .
```

Build the audio target when required:

```bash
docker build --target audio -t local-voicemode-audio:test .
```

Source checks:

```bash
python -m compileall -q service frontend integrations tests
bash -n service/talk.sh service/tts.sh service/tts_backends.sh
python -m unittest tests.test_xai_sentence_tagger -v
python -m unittest tests.test_tts_wrapper -v
python -m unittest tests.test_ai_tts_provider -v
```

Physical microphone, speaker, host service-manager, large model download, and paid-provider smoke tests remain host-specific.

## Cleanup

Stop containers without deleting configuration:

```bash
docker compose down
```

Delete the named configuration volume only when permanent reset is intended:

```bash
docker compose down -v
```

The Linux audio container stores transient recordings in its tmpfs `/tmp`; removing the container removes those files.
