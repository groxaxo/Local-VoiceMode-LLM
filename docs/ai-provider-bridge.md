# Shared AI TTS provider bridge

Local VoiceMode LLM remains local-first by default. The optional AI provider bridge connects the Unix/macOS conversation loop to a local **AI Sentence Tagger** or **AI Voice Studio** service when provider-correct xAI or Google Gemini direction is required.

## Why use a companion service?

The built-in `service/tts.sh` is a lightweight shell dispatcher. The companion projects provide a deeper provider contract:

- verified 26-voice xAI and 30-voice Gemini catalogs;
- fixed xAI grammar versus creative Gemini direction semantics;
- exact source-preservation validation;
- local OpenAI-compatible LLM tagging;
- Google Interactions audio extraction and PCM-to-WAV conversion;
- provider-aware manifests, REST, CLI, and MCP.

The bridge reuses that implementation through `/api/process/json` instead of copying the catalogs into Local VoiceMode.

## Data flow

```text
agent reply
    │
    ▼
talk.sh
    │ TTS_SH override
    ▼
tts-provider.sh
    │ POST /api/process/json
    ▼
AI Sentence Tagger / AI Voice Studio :8000
    ├── local OpenAI-compatible tagger
    ├── provider validator
    └── xAI or Google synthesis
             │
             ▼
       base64 provider WAV
             │
             ▼
strict decode + atomic local WAV
             │
             ▼
playback / pre-warmed listen / barge-in
```

## Install

```bash
bash integrations/ai-sentence-tagger/install.sh
```

## Google example

```bash
export TTS_SH="$HOME/.config/opencode/ai-tts-provider/tts-provider.sh"
export AI_TTS_URL=http://127.0.0.1:8000
export AI_TTS_PROVIDER=google
export AI_TTS_VOICE=Kore
export AI_TTS_STYLE_PROMPT='Clear, friendly technical assistant'

~/.config/opencode/skills/talk/talk.sh speak "The validation passed."
```

## xAI example

```bash
export TTS_SH="$HOME/.config/opencode/ai-tts-provider/tts-provider.sh"
export AI_TTS_URL=http://127.0.0.1:8000
export AI_TTS_PROVIDER=xai
export AI_TTS_VOICE=eve

~/.config/opencode/skills/talk/talk.sh speak "The validation passed."
```

## Important boundary

`TTS_SH` is an implementation override, not a new `TTS_ENGINE` value. Once set, the bridge replaces `service/tts.sh` for that process. Unset `TTS_SH` to restore the repository's built-in local-first fallback graph.

## Companion security boundary

The bridge contains no xAI or Google credentials. Provider keys and tagging-model configuration stay in the companion service. Bind it to loopback or protect it with a private reverse proxy; `AI_TTS_TOKEN` adds an optional bearer header.

## More detail

- [Integration guide](../integrations/ai-sentence-tagger/README.md)
- [Provider and fallback reference](providers.md)
