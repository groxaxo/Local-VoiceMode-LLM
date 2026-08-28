#!/usr/bin/env python3
"""Strict sentence-by-sentence xAI speech tagger for Local VoiceMode LLM.

The helper uses an OpenAI-compatible LLM when configured and always validates the
result. Missing, malformed, or source-rewriting model output is repaired with a
deterministic provider-correct tag so every spoken sentence has at least one xAI
speech tag before synthesis.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from typing import Any
from urllib import error as urllib_error
from urllib import request as urllib_request

XAI_INLINE_TAGS: tuple[str, ...] = (
    "pause",
    "long-pause",
    "hum-tune",
    "laugh",
    "chuckle",
    "giggle",
    "cry",
    "tsk",
    "tongue-click",
    "lip-smack",
    "breath",
    "inhale",
    "exhale",
    "sigh",
)
XAI_WRAPPING_TAGS: tuple[str, ...] = (
    "soft",
    "whisper",
    "loud",
    "build-intensity",
    "decrease-intensity",
    "higher-pitch",
    "lower-pitch",
    "slow",
    "fast",
    "sing-song",
    "singing",
    "laugh-speak",
    "emphasis",
)
_INLINE_SET = frozenset(XAI_INLINE_TAGS)
_WRAPPER_SET = frozenset(XAI_WRAPPING_TAGS)
_TAG_AT_RE = re.compile(r"\[([a-z][a-z-]*)\]|<(\/)?([a-z][a-z-]*)>", re.IGNORECASE)
_BOUNDARY_RE = re.compile(r"[.!?]+(?:[\"'”’»）)\]]+)?(?=\s+|$)", re.UNICODE)
_JSON_OBJECT_RE = re.compile(r"\{.*\}", re.DOTALL)
_COMMON_ABBREVIATIONS = frozenset(
    {
        "mr.",
        "mrs.",
        "ms.",
        "dr.",
        "prof.",
        "sr.",
        "jr.",
        "st.",
        "vs.",
        "etc.",
        "e.g.",
        "i.e.",
        "no.",
        "fig.",
    }
)


class TaggingError(RuntimeError):
    """Safe sentence-tagger failure."""


@dataclass(frozen=True, slots=True)
class SentenceSpan:
    index: int
    start: int
    end: int
    text: str


@dataclass(frozen=True, slots=True)
class TaggedSentence:
    index: int
    original: str
    tagged_text: str
    tags: tuple[str, ...]
    source: str
    warning: str | None = None


def _env_text(name: str) -> str | None:
    value = os.getenv(name)
    if value is None:
        return None
    value = value.strip()
    return value or None


def _is_abbreviation(text: str, boundary_start: int, boundary_end: int) -> bool:
    punctuation = text[boundary_start:boundary_end]
    if punctuation != ".":
        return False
    prefix = text[:boundary_end]
    match = re.search(r"([A-Za-z](?:[A-Za-z.]*)\.)$", prefix)
    if not match:
        return False
    token = match.group(1).casefold()
    if token in _COMMON_ABBREVIATIONS:
        return True
    return len(token) == 2 and token[0].isalpha()


def sentence_spans(text: str) -> list[SentenceSpan]:
    """Split text into source-preserving sentence spans."""
    spans: list[SentenceSpan] = []
    start = 0
    for match in _BOUNDARY_RE.finditer(text):
        if _is_abbreviation(text, match.start(), match.end()):
            continue
        end = match.end()
        segment = text[start:end]
        if segment.strip():
            spans.append(SentenceSpan(len(spans), start, end, segment))
        start = end
    if start < len(text):
        segment = text[start:]
        if segment.strip():
            spans.append(SentenceSpan(len(spans), start, len(text), segment))
    if not spans and text.strip():
        spans.append(SentenceSpan(0, 0, len(text), text))
    return spans


def _split_outer_whitespace(text: str) -> tuple[str, str, str]:
    leading_size = len(text) - len(text.lstrip())
    trailing_size = len(text) - len(text.rstrip())
    end = len(text) - trailing_size if trailing_size else len(text)
    return text[:leading_size], text[leading_size:end], text[end:]


def _tag_token_at(text: str, offset: int) -> tuple[int, str, bool] | None:
    match = _TAG_AT_RE.match(text, offset)
    if match is None:
        return None
    inline, closing, wrapper = match.groups()
    if inline:
        tag = inline.casefold()
        return (match.end(), tag, True) if tag in _INLINE_SET else None
    assert wrapper is not None
    tag = wrapper.casefold()
    if tag not in _WRAPPER_SET:
        return None
    return match.end(), tag, not bool(closing)


def inserted_tags(original: str, tagged: str) -> tuple[list[str], bool]:
    """Return newly inserted xAI tags and whether source text is exact."""
    source_offset = 0
    tagged_offset = 0
    found: list[str] = []

    while source_offset < len(original):
        token = _tag_token_at(tagged, tagged_offset)
        if token is not None:
            end, tag, opening = token
            literal = tagged[tagged_offset:end]
            if not original.startswith(literal, source_offset):
                if opening:
                    found.append(tag)
                tagged_offset = end
                continue
        if tagged_offset >= len(tagged) or tagged[tagged_offset] != original[source_offset]:
            return [], False
        tagged_offset += 1
        source_offset += 1

    while tagged_offset < len(tagged):
        token = _tag_token_at(tagged, tagged_offset)
        if token is None:
            return [], False
        tagged_offset, tag, opening = token
        if opening:
            found.append(tag)
    return found, True


def _wrapper_errors(tagged: str) -> list[str]:
    stack: list[str] = []
    errors: list[str] = []
    for match in re.finditer(r"<(\/)?([a-z][a-z-]*)>", tagged, re.IGNORECASE):
        closing, raw = match.groups()
        tag = raw.casefold()
        if tag not in _WRAPPER_SET:
            continue
        if not closing:
            stack.append(tag)
        elif not stack:
            errors.append(f"closing </{tag}> has no opener")
        else:
            expected = stack.pop()
            if expected != tag:
                errors.append(f"expected </{expected}> but found </{tag}>")
    errors.extend(f"unclosed <{tag}>" for tag in reversed(stack))
    return errors


def validate_tagged_sentence(original: str, tagged: str) -> tuple[list[str], list[str]]:
    tags, preserved = inserted_tags(original, tagged)
    errors: list[str] = []
    if not preserved:
        errors.append("tagged output changed the original sentence")
    if not tags:
        errors.append("sentence has no inserted xAI speech tag")
    errors.extend(_wrapper_errors(tagged))
    return errors, tags


def deterministic_tag(sentence: str, index: int) -> TaggedSentence:
    leading, core, trailing = _split_outer_whitespace(sentence)
    if not core:
        raise TaggingError(f"Sentence {index} is blank")
    kind = "wrapper"
    tag = "emphasis"

    rules: tuple[tuple[re.Pattern[str], str, str], ...] = (
        (
            re.compile(r"\b(secret|secreto|susurr|whisper|quiet|silencio)\b", re.I),
            "wrapper",
            "whisper",
        ),
        (
            re.compile(
                r"\b(miedo|terror|panic|pánico|danger|peligro|sad|triste|dolor)\b",
                re.I,
            ),
            "wrapper",
            "lower-pitch",
        ),
        (
            re.compile(r"\b(laugh|laughed|funny|risa|reí|gracioso|absurdo)\b", re.I),
            "inline",
            "chuckle",
        ),
        (
            re.compile(r"\b(calm|calma|slow|lento|despacio|suave)\b", re.I),
            "wrapper",
            "slow",
        ),
        (
            re.compile(
                r"\b(fast|quick|urgent|urgencia|rápido|suddenly|de pronto)\b",
                re.I,
            ),
            "wrapper",
            "fast",
        ),
    )
    for pattern, rule_kind, rule_tag in rules:
        if pattern.search(core):
            kind, tag = rule_kind, rule_tag
            break
    else:
        if "!" in core:
            kind, tag = "wrapper", "loud"
        elif "?" in core:
            kind, tag = "wrapper", "higher-pitch"
        else:
            cycle = (
                ("wrapper", "emphasis"),
                ("inline", "breath"),
                ("wrapper", "soft"),
                ("inline", "pause"),
                ("wrapper", "build-intensity"),
                ("inline", "sigh"),
            )
            kind, tag = cycle[index % len(cycle)]

    if kind == "inline":
        directed = f"[{tag}]{core}"
    else:
        directed = f"<{tag}>{core}</{tag}>"
    tagged = leading + directed + trailing
    errors, tags = validate_tagged_sentence(sentence, tagged)
    if errors:
        raise TaggingError(f"Deterministic tag failed for sentence {index}: {'; '.join(errors)}")
    return TaggedSentence(index, sentence, tagged, tuple(tags), "deterministic")


def _chat_completions_url(base_url: str) -> str:
    value = base_url.rstrip("/")
    if value.endswith("/chat/completions"):
        return value
    if value.endswith("/v1"):
        return value + "/chat/completions"
    return value + "/v1/chat/completions"


def _llm_system_prompt(language: str) -> str:
    inline = " ".join(f"[{tag}]" for tag in XAI_INLINE_TAGS)
    wrapping = " ".join(f"<{tag}>...</{tag}>" for tag in XAI_WRAPPING_TAGS)
    return f"""You are a strict xAI speech-direction editor.
Add at least one valid xAI speech tag to EVERY supplied sentence while preserving every
original character exactly. Return JSON only:
{{"sentences":[{{"index":0,"tagged_text":"..."}}]}}

Allowed inline tags:
{inline}

Allowed wrapping tags:
{wrapping}

Rules:
1. One output row per input index; no missing or duplicate indexes.
2. Every sentence must contain at least one newly inserted valid tag.
3. Do not rewrite, translate, delete, reorder, correct, or normalize source characters.
4. Usually use one contextually appropriate tag; avoid noisy over-tagging.
5. Return no Markdown or commentary.
6. Language hint: {language!r}. Preserve the language and dialect.
"""


def _extract_json_object(content: str) -> dict[str, Any]:
    try:
        payload = json.loads(content)
    except json.JSONDecodeError:
        match = _JSON_OBJECT_RE.search(content)
        if match is None:
            raise TaggingError("Tagging model did not return JSON") from None
        try:
            payload = json.loads(match.group(0))
        except json.JSONDecodeError as exc:
            raise TaggingError("Tagging model returned malformed JSON") from exc
    if not isinstance(payload, dict):
        raise TaggingError("Tagging model response must be a JSON object")
    return payload


def _request_llm(sentences: list[SentenceSpan], language: str) -> dict[int, str]:
    base_url = _env_text("TTS_TAGGER_URL") or _env_text("LLM_BASE_URL")
    model = _env_text("TTS_TAGGER_MODEL") or _env_text("LLM_MODEL")
    if not base_url or not model:
        raise TaggingError("TTS_TAGGER_URL and TTS_TAGGER_MODEL are not configured")
    key = _env_text("TTS_TAGGER_API_KEY") or _env_text("LLM_API_KEY")
    try:
        temperature = float(_env_text("TTS_TAGGER_TEMPERATURE") or "0.2")
        timeout = float(_env_text("TTS_TAGGER_TIMEOUT_SECONDS") or "30")
    except ValueError as exc:
        raise TaggingError("TTS tagger temperature and timeout must be numeric") from exc
    if timeout <= 0:
        raise TaggingError("TTS_TAGGER_TIMEOUT_SECONDS must be greater than zero")

    request_payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": _llm_system_prompt(language)},
            {
                "role": "user",
                "content": json.dumps(
                    {
                        "sentences": [
                            {"index": sentence.index, "text": sentence.text}
                            for sentence in sentences
                        ]
                    },
                    ensure_ascii=False,
                ),
            },
        ],
        "temperature": temperature,
        "stream": False,
        "response_format": {"type": "json_object"},
    }
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if key and key != "not-needed":
        headers["Authorization"] = f"Bearer {key}"

    def send(payload: dict[str, Any]) -> dict[str, Any]:
        req = urllib_request.Request(
            _chat_completions_url(base_url),
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        try:
            with urllib_request.urlopen(req, timeout=timeout) as response:
                raw = response.read()
        except urllib_error.HTTPError as exc:
            detail = exc.read(1000).decode("utf-8", errors="replace").strip()
            raise TaggingError(
                f"Tagging model returned HTTP {exc.code}: {detail or exc.reason}"
            ) from exc
        except urllib_error.URLError as exc:
            raise TaggingError(f"Cannot reach tagging model: {exc.reason}") from exc
        except TimeoutError as exc:
            raise TaggingError(f"Tagging model timed out after {timeout:g} seconds") from exc
        try:
            decoded = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise TaggingError("Tagging endpoint returned malformed JSON") from exc
        if not isinstance(decoded, dict):
            raise TaggingError("Tagging endpoint returned non-object JSON")
        return decoded

    try:
        response = send(request_payload)
    except TaggingError as first_error:
        fallback_payload = dict(request_payload)
        fallback_payload.pop("response_format", None)
        try:
            response = send(fallback_payload)
        except TaggingError:
            raise first_error

    try:
        content = response["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as exc:
        raise TaggingError("Tagging endpoint response is missing choices[0].message.content") from exc
    if not isinstance(content, str):
        raise TaggingError("Tagging endpoint message content is not text")
    payload = _extract_json_object(content)
    rows = payload.get("sentences")
    if not isinstance(rows, list):
        raise TaggingError("Tagging model response is missing a sentences array")
    result: dict[int, str] = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        index = row.get("index")
        tagged_text = row.get("tagged_text")
        if isinstance(index, int) and isinstance(tagged_text, str) and index not in result:
            result[index] = tagged_text
    return result


def tag_text(text: str, language: str = "auto", mode: str | None = None) -> dict[str, Any]:
    if not text.strip():
        raise TaggingError("Refusing to tag blank text")
    selected_mode = (mode or _env_text("TTS_TAG_MODE") or "auto").strip().casefold()
    if selected_mode not in {"auto", "llm", "deterministic"}:
        raise TaggingError("TTS_TAG_MODE must be auto, llm, or deterministic")

    spans = sentence_spans(text)
    if not spans:
        raise TaggingError("No spoken sentences were found")

    llm_rows: dict[int, str] = {}
    llm_warning: str | None = None
    if selected_mode in {"auto", "llm"}:
        try:
            llm_rows = _request_llm(spans, language)
        except TaggingError as exc:
            llm_warning = str(exc)

    tagged_sentences: list[TaggedSentence] = []
    for sentence in spans:
        candidate = llm_rows.get(sentence.index)
        if candidate is not None:
            errors, tags = validate_tagged_sentence(sentence.text, candidate)
            if not errors:
                tagged_sentences.append(
                    TaggedSentence(
                        sentence.index,
                        sentence.text,
                        candidate,
                        tuple(tags),
                        "llm",
                        llm_warning,
                    )
                )
                continue
            warning = "; ".join(errors)
        else:
            warning = llm_warning or "Tagging model omitted this sentence"
        repaired = deterministic_tag(sentence.text, sentence.index)
        tagged_sentences.append(
            TaggedSentence(
                repaired.index,
                repaired.original,
                repaired.tagged_text,
                repaired.tags,
                repaired.source,
                warning if selected_mode != "deterministic" else None,
            )
        )

    if len(tagged_sentences) != len(spans):
        raise TaggingError("Internal error: sentence count changed during tagging")
    failures: list[int] = []
    for item in tagged_sentences:
        errors, _ = validate_tagged_sentence(item.original, item.tagged_text)
        if errors:
            failures.append(item.index)
    if failures:
        joined = ", ".join(str(index) for index in failures)
        raise TaggingError(f"Could not produce a valid tag for sentence indexes: {joined}")

    replacements = {item.index: item.tagged_text for item in tagged_sentences}
    cursor = 0
    rebuilt: list[str] = []
    for sentence in spans:
        rebuilt.append(text[cursor:sentence.start])
        rebuilt.append(replacements[sentence.index])
        cursor = sentence.end
    rebuilt.append(text[cursor:])
    tagged_text = "".join(rebuilt)

    return {
        "provider": "xai",
        "mode_requested": selected_mode,
        "sentence_count": len(spans),
        "tagged_sentence_count": len(tagged_sentences),
        "untagged_sentence_indexes": [],
        "tagged_text": tagged_text,
        "sentences": [
            {
                "index": item.index,
                "original": item.original,
                "tagged_text": item.tagged_text,
                "tags": list(item.tags),
                "source": item.source,
                "warning": item.warning,
            }
            for item in tagged_sentences
        ],
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Add at least one valid xAI speech tag to every sentence."
    )
    parser.add_argument("--text", help="Text to tag; defaults to stdin")
    parser.add_argument("--language", default="auto")
    parser.add_argument("--mode", choices=("auto", "llm", "deterministic"))
    parser.add_argument("--format", choices=("text", "json"), default="json")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        source_text = args.text if args.text is not None else sys.stdin.read()
        result = tag_text(source_text, args.language, args.mode)
    except TaggingError as exc:
        print(f"xai-sentence-tagger: {exc}", file=sys.stderr)
        return 1
    if args.format == "text":
        print(result["tagged_text"], end="")
    else:
        print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
