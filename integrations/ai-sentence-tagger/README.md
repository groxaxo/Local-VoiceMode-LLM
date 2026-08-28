# AI Sentence Tagger / AI Voice Studio bridge

This integration lets the Unix Local VoiceMode orchestrator use the **same provider catalogs, direction validator, and synthesis clients** as:

- [AI Sentence Tagger](https://github.com/groxaxo/xai-sentence-tagger)
- [AI Voice Studio](https://github.com/groxaxo/xAI-Voice-Studio)

The bridge does not duplicate xAI or Gemini tag logic. It calls a trusted companion service's stateless `POST /api/process/json` endpoint, which:

1. tags the utterance with the selected provider grammar;
2. validates exact source preservation;
3. synthesizes the selected voice;
4. returns canonical provider/voice metadata and base64 audio.

The companion owns the local tagging model and cloud credentials. The Local VoiceMode process receives only the final WAV.

## Supported contracts

| Provider | Voices | Default voice | Direction model | Bridge WAV |
|---|---:|---|---|---:|
| xAI | 26 | `eve` | fixed 14 inline + 13 wrapping tags | 48 kHz |
| Google Gemini | 30 | `Kore` | 16 common examples plus creative English direction | 24 kHz |

`gemini` is accepted as an alias for `google`.

Google's 16 examples are not an exhaustive allowlist. The companion service remains the source of truth for creative directions, lexical-boundary safeguards, canonical voice casing, and PCM-to-WAV handling.

## 1. Start a companion service

Use either repository.

### AI Sentence Tagger

```bash
git clone https://github.com/groxaxo/xai-sentence-tagger.git
cd xai-sentence-tagger
python -m venv .venv
source .venv/bin/activate
python -m pip install -e .
cp .env.example .env
ai-tagger serve --host 127.0.0.1 --port 8000
```

### AI Voice Studio

```bash
git clone https://github.com/groxaxo/xAI-Voice-Studio.git
cd xAI-Voice-Studio
python -m venv .venv
source .venv/bin/activate
python -m pip install -e .
cp .env.example .env
ai-voice-studio serve --host 127.0.0.1 --port 8000
```

Configure the companion's OpenAI-compatible tagging model plus the provider keys it will use. Keep those credentials on the companion service.

## 2. Install the bridge

From Local VoiceMode LLM:

```bash
bash integrations/ai-sentence-tagger/install.sh
```

This installs:

```text
~/.config/opencode/ai-tts-provider/
├── tts_provider.py
└── tts-provider.sh
```

## 3. Route Local VoiceMode through it

### Google Gemini

```bash
export TTS_SH="$HOME/.config/opencode/ai-tts-provider/tts-provider.sh"
export AI_TTS_URL=http://127.0.0.1:8000
export AI_TTS_PROVIDER=google
export AI_TTS_VOICE=Kore
export AI_TTS_LANGUAGE=auto

~/.config/opencode/skills/talk/talk.sh speak "The deployment completed."
```

### xAI

```bash
export TTS_SH="$HOME/.config/opencode/ai-tts-provider/tts-provider.sh"
export AI_TTS_URL=http://127.0.0.1:8000
export AI_TTS_PROVIDER=xai
export AI_TTS_VOICE=eve
export AI_TTS_LANGUAGE=auto

~/.config/opencode/skills/talk/talk.sh speak "The deployment completed."
```

`talk.sh` passes the detected source language to the bridge. `AI_TTS_LANGUAGE` overrides the synthesis language when set.

## Catalog inspection

```bash
python3 ~/.config/opencode/ai-tts-provider/tts_provider.py providers
python3 ~/.config/opencode/ai-tts-provider/tts_provider.py voices --provider xai
python3 ~/.config/opencode/ai-tts-provider/tts_provider.py voices --provider google
python3 ~/.config/opencode/ai-tts-provider/tts_provider.py tags --provider google
python3 ~/.config/opencode/ai-tts-provider/tts_provider.py audio-formats --provider google
python3 ~/.config/opencode/ai-tts-provider/tts_provider.py health
```

Catalog results come from the running companion, so they stay aligned with its tested contracts.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `TTS_SH` | built-in `service/tts.sh` | Point to `tts-provider.sh` to select this integration |
| `AI_TTS_URL` | `http://127.0.0.1:8000` | Companion service base URL |
| `AI_TTS_PROVIDER` | `xai` | `xai`, `google`, or `gemini` |
| `AI_TTS_VOICE` | provider default | Case-insensitive built-in voice ID |
| `AI_TTS_SOURCE_LANGUAGE` | language passed by `talk.sh` | Override tagging language hint |
| `AI_TTS_LANGUAGE` | source language | Synthesis language or `auto` |
| `AI_TTS_COVERAGE` | `natural` | `natural`, `all`, or `all-per-sentence` |
| `AI_TTS_STYLE_PROMPT` | unset | Gemini Director's Notes |
| `AI_TTS_MODEL` | companion default | Gemini TTS model override |
| `AI_TTS_TAGGER_MODEL` | companion default | Tagging-model override |
| `AI_TTS_TAGGER_BASE_URL` | companion default | Tagging endpoint override |
| `AI_TTS_TIMEOUT_SECONDS` | `180` | HTTP timeout |
| `AI_TTS_MAX_AUDIO_BYTES` | `100000000` | Decoded-audio safety limit |
| `AI_TTS_TOKEN` | unset | Optional bearer token for a protected companion |
| `AI_TTS_PYTHON` | `python3` | Python used by the shell adapter |

`AI_TTS_CODEC` must remain `wav`. `AI_TTS_SAMPLE_RATE` is an advanced override and must match a format accepted by the active provider.

## VoiceMode contract

The shell adapter implements the same interface expected from `service/tts.sh`:

```text
input:  text as argument 1, language hint as argument 2
normal mode: synthesize and play
TTS_NO_PLAY=1: print one WAV path to stdout
diagnostics: stderr
```

This preserves pre-warmed listening and barge-in workflows.

The bridge validates:

- JSON response shape;
- strict base64;
- maximum decoded size;
- `audio/wav` metadata;
- RIFF/WAVE container signature;
- atomic output-file replacement.

## Routing and fallback implications

Setting `TTS_SH` to this adapter **replaces** the built-in Unix dispatcher for that process. The normal Supertonic/Qwen/NeuTTS/xAI fallback graph is not entered automatically.

To return to the local-first dispatcher:

```bash
unset TTS_SH
export TTS_ENGINE=supertonic
```

For automatic failover between the companion and local engines, place your own wrapper in `TTS_SH` that calls this bridge first and `service/tts.sh` second.

## Persistence

The bridge uses `/api/process/json`, even when connected to AI Voice Studio. These utterances are stateless and do not create browser-visible Studio projects or jobs. Use the Studio browser or `/api/studio/*` endpoints when durable project history is required.

## Security

- Bind the companion to loopback or a protected private network.
- Keep xAI, Google, and tagging-model credentials in the companion environment.
- Use `AI_TTS_TOKEN` when a reverse proxy protects the companion with a bearer token.
- The bridge sends reply text to the companion; the companion may then send directed text to the selected hosted speech provider.
- Do not place credentials in `AI_TTS_STYLE_PROMPT`, agent prompts, shell history, or committed files.

## Platform scope

`tts-provider.sh` integrates directly with the Unix/macOS `talk.sh` path. The Python helper itself is cross-platform, but the Windows `talk.ps1` dispatcher is a separate implementation and is not automatically redirected by this installer.

See [speech providers and fallback policy](../../docs/providers.md).
