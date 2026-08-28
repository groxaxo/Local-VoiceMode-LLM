# Mandatory xAI sentence tagging

Every xAI synthesis request made by the Unix Local VoiceMode runtime now carries at least one valid xAI speech tag for every segmented sentence.

This is a hard pre-audio invariant, not a prompt preference.

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

Makes no tagging-model request. Contextual punctuation and keyword rules choose from the fixed xAI grammar, with a deterministic cycle for neutral sentences.

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
- 13 wrapping tags
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
