# Mandatory xAI sentence tagging

Every xAI synthesis request made by the Unix Local VoiceMode runtime now carries at least one valid xAI speech tag for every segmented sentence.

Full coverage is this project's user-selected policy. xAI documents tags as optional
expressive controls; it does not require a tag on each sentence. The local wrapper
still enforces complete coverage before contacting xAI.

## Official reference and review

Checked on **2026-10-28** using the configured private Context7 MCP against the
[xAI TTS guide](https://docs.x.ai/developers/model-capabilities/audio/text-to-speech#speech-tags)
and [REST voice reference](https://docs.x.ai/developers/rest-api-reference/inference/voice).
Both currently list **14 inline tags and 12 wrapping tags**. `<laugh-speak>` is
not in that reference and is rejected, along with invented directions such as
`[cheerfully]`.

| Type | Supported names |
|---|---|
| Inline `[tag]` | `pause`, `long-pause`, `hum-tune`, `laugh`, `chuckle`, `giggle`, `cry`, `tsk`, `tongue-click`, `lip-smack`, `breath`, `inhale`, `exhale`, `sigh` |
| Wrapping `<tag>phrase</tag>` | `soft`, `whisper`, `loud`, `build-intensity`, `decrease-intensity`, `higher-pitch`, `lower-pitch`, `slow`, `fast`, `sing-song`, `singing`, `emphasis` |

The allowlist in `service/xai_sentence_tagger.py` is shared by the formatter and
the independent pre-request validator. API changes require updating the allowlist,
the contract regression test, and this review date together.

## Delivery policy

Following xAI's placement guidance, the formatter is instructed to put inline
expressions at their intended point, use punctuation for timing, and wrap complete
phrases. Balanced nested styles such as `<slow><soft>...</soft></slow>` are valid.
Empty styles do not direct any spoken words and are rejected.

The offline fallback keeps every sentence tagged with one complete-phrase
`<emphasis>` wrapper unless the sentence contains an explicit delivery request
such as “Please whisper this part.” It preserves all source characters and
whitespace. Mentioning a laugh or an urgent event does not inject a chuckle or
change the speed. Sentence position does not add breaths, pauses, sighs, or
intensity changes, and punctuation alone does not force loudness or pitch.

```text
Source:   The build passed. The report is ready!
Fallback: <emphasis>The build passed.</emphasis> <emphasis>The report is ready!</emphasis>
```

The LLM may choose other supported directions when context warrants them. The
phrase-emphasis fallback is our conservative implementation choice for full
coverage, not an xAI prescription or a guarantee of subjective audio quality.

## Request path

```text
reply text
   │
   ▼
service/tts.sh                         safety wrapper
   │
   ├─ non-xAI engine ─► service/tts_backends.sh
   │                         │
   │                         └─ failure ───────────┐
   │                                               │
   └─ xAI selected ────────────────────────────────┤
                                                   ▼
                                service/xai_sentence_tagger.py
                                                   │
                                                   ├─ segment every sentence
                                                   ├─ optional local LLM direction
                                                   ├─ exact source validation
                                                   ├─ deterministic repair
                                                   └─ assert N/N sentences tagged
                                                   │
                                                   ▼
                                          POST xAI /v1/tts
```

The historical engine implementations remain in `service/tts_backends.sh`. The wrapper clears `XAI_API_KEY` while running that dispatcher, which makes its legacy raw-xAI fallback unreachable. If the selected/local backends fail, control returns to the wrapper and the final xAI attempt passes through the same sentence tagger.

## Invariant

The helper emits structured proof:

```json
{
  "provider": "xai",
  "sentence_count": 3,
  "tagged_sentence_count": 3,
  "untagged_sentence_indexes": [],
  "tagged_text": "...",
  "sentences": [
    {
      "index": 0,
      "original": "Hello.",
      "tagged_text": "<emphasis>Hello.</emphasis>",
      "tags": ["emphasis"],
      "source": "deterministic"
    }
  ]
}
```

`service/tts.sh` independently checks the counts, indexes, inserted-tag lists, and reconstructed tagged text before building the xAI request. If the proof is incomplete, no provider request is made.

## Tag modes

### `auto`

```bash
export TTS_TAG_MODE=auto
```

Uses the configured OpenAI-compatible model when available. Each model row is validated independently. Missing, malformed, unknown-tag, unbalanced, or source-rewriting output is replaced deterministically.

### `llm`

```bash
export TTS_TAG_MODE=llm
```

Attempts the configured model first and still applies deterministic sentence repair. It therefore retains the same 100% invariant when the model omits or corrupts one sentence.

### `deterministic`

```bash
export TTS_TAG_MODE=deterministic
```

Makes no tagging-model request. Uses explicit delivery requests where present and the complete-phrase emphasis fallback elsewhere. It never selects a sound effect from the sentence index.

## Local LLM configuration

```bash
export TTS_TAGGER_URL=http://127.0.0.1:12434/v1
export TTS_TAGGER_MODEL=your-local-model
export TTS_TAGGER_API_KEY=not-needed
export TTS_TAGGER_TEMPERATURE=0.2
export TTS_TAGGER_TIMEOUT_SECONDS=30
```

`TTS_TAGGER_URL` accepts either an OpenAI-compatible base URL, a `/v1` URL, or the complete `/chat/completions` URL.

The model receives the exact fixed xAI grammar:

- 14 inline tags
- 12 wrapping tags
- one output row per indexed source sentence
- no source rewriting

## Direct use

Inspect the tagging result without synthesizing:

```bash
printf '%s' 'Hello. Are you there?' | \
  python3 service/xai_sentence_tagger.py \
    --mode deterministic \
    --language en \
    --format json | python3 -m json.tool
```

Synthesize through xAI:

```bash
export TTS_ENGINE=xai
export XAI_API_KEY=replace-me
export XAI_TTS_VOICE=eve
export TTS_TAG_MODE=auto

TTS_NO_PLAY=1 bash service/tts.sh \
  'Hello. Are you there?' en
```

`TTS_NO_PLAY=1` prints the generated WAV path. The same path is used by pre-warmed listening and barge-in.

## Companion-service bridge

The optional AI Sentence Tagger / AI Voice Studio bridge has an independent form of the same rule. It requests `include_annotations=true` from `/api/process/json` and refuses returned audio unless:

- `tagged_sentence_count == sentence_count`;
- `untagged_sentence_indexes` is empty;
- there is one unique annotation per sentence; and
- every annotation differs from its original source sentence.

This means both available xAI paths—the built-in Unix wrapper and the companion bridge—fail before playback when a sentence lacks direction.

## Fallback semantics

For non-xAI engines, the existing local/remote order still runs first. Only after a normal backend failure may the wrapper use sentence-tagged xAI.

Terminal dispatcher errors remain terminal:

- unknown `TTS_ENGINE` exits with status 2;
- explicit credential refusals such as Inworld HTTP 401/403 exit with status 3;
- neither is hidden by an xAI fallback.

## Validation

```bash
python -m py_compile service/xai_sentence_tagger.py
bash -n service/tts.sh service/tts_backends.sh
python -m unittest tests.test_xai_sentence_tagger -v
python -m unittest tests.test_tts_wrapper -v
python -m unittest tests.test_ai_tts_provider -v
```

The deterministic tests inspect the exact xAI JSON payload and verify that every source sentence is represented by valid, source-preserving tagged text before the fake provider is called.
