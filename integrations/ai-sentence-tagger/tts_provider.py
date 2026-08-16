#!/usr/bin/env python3
"""Provider-aware Local VoiceMode bridge to AI Sentence Tagger / AI Voice Studio."""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any
from urllib import error as urllib_error
from urllib import request as urllib_request

DEFAULT_URL = "http://127.0.0.1:8000"
DEFAULT_TIMEOUT_SECONDS = 180.0
DEFAULT_MAX_AUDIO_BYTES = 100_000_000
_PROVIDER_ALIASES = {
    "xai": "xai",
    "x-ai": "xai",
    "grok": "xai",
    "google": "google",
    "google-ai": "google",
    "googleai": "google",
    "gemini": "google",
}
_COVERAGE_MODES = {"natural", "all", "all-per-sentence"}


class BridgeError(RuntimeError):
    """Safe, user-facing bridge failure."""


def normalize_provider(value: str | None) -> str:
    candidate = (value or "xai").strip().lower().replace("_", "-")
    try:
        return _PROVIDER_ALIASES[candidate]
    except KeyError as exc:
        raise BridgeError(
            f"Unsupported AI_TTS_PROVIDER {value!r}; use xai, google, or gemini"
        ) from exc


def provider_output_format(provider: str) -> dict[str, Any]:
    """Return a WAV format suitable for Local VoiceMode playback/barge-in."""
    if normalize_provider(provider) == "google":
        return {"codec": "wav", "sample_rate": 24000, "bit_rate": None}
    return {"codec": "wav", "sample_rate": 48000, "bit_rate": None}


def _env_text(name: str) -> str | None:
    value = os.getenv(name)
    if value is None:
        return None
    value = value.strip()
    return value or None


def _positive_float(name: str, default: float) -> float:
    raw = _env_text(name)
    if raw is None:
        return default
    try:
        value = float(raw)
    except ValueError as exc:
        raise BridgeError(f"{name} must be a number") from exc
    if value <= 0:
        raise BridgeError(f"{name} must be greater than zero")
    return value


def _positive_int(name: str, default: int) -> int:
    raw = _env_text(name)
    if raw is None:
        return default
    try:
        value = int(raw)
    except ValueError as exc:
        raise BridgeError(f"{name} must be an integer") from exc
    if value <= 0:
        raise BridgeError(f"{name} must be greater than zero")
    return value


def build_process_payload(
    text: str,
    *,
    provider: str,
    source_language: str,
) -> dict[str, Any]:
    if not text.strip():
        raise BridgeError("Refusing to synthesize blank text")

    resolved = normalize_provider(provider)
    coverage = (_env_text("AI_TTS_COVERAGE") or "natural").lower()
    if coverage not in _COVERAGE_MODES:
        choices = ", ".join(sorted(_COVERAGE_MODES))
        raise BridgeError(f"AI_TTS_COVERAGE must be one of: {choices}")

    output_format = provider_output_format(resolved)
    codec = (_env_text("AI_TTS_CODEC") or output_format["codec"]).lower()
    if codec != "wav":
        raise BridgeError(
            "Local VoiceMode's AI provider bridge requires WAV output; "
            "set AI_TTS_CODEC=wav"
        )
    sample_rate_text = _env_text("AI_TTS_SAMPLE_RATE")
    if sample_rate_text is not None:
        try:
            output_format["sample_rate"] = int(sample_rate_text)
        except ValueError as exc:
            raise BridgeError("AI_TTS_SAMPLE_RATE must be an integer") from exc
    output_format["codec"] = "wav"
    output_format["bit_rate"] = None

    language = (_env_text("AI_TTS_SOURCE_LANGUAGE") or source_language or "auto").strip()
    tts_language = _env_text("AI_TTS_LANGUAGE") or language or "auto"

    payload: dict[str, Any] = {
        "text": text,
        "provider": resolved,
        "language": language,
        "coverage_mode": coverage,
        "include_annotations": False,
        "tts_language": tts_language,
        "output_format": output_format,
    }

    optional = {
        "voice_id": _env_text("AI_TTS_VOICE"),
        "style_prompt": _env_text("AI_TTS_STYLE_PROMPT"),
        "tts_model": _env_text("AI_TTS_MODEL"),
        "model": _env_text("AI_TTS_TAGGER_MODEL"),
        "base_url": _env_text("AI_TTS_TAGGER_BASE_URL"),
    }
    payload.update({key: value for key, value in optional.items() if value is not None})
    return payload


def _base_url() -> str:
    return (_env_text("AI_TTS_URL") or DEFAULT_URL).rstrip("/")


def _headers(*, json_body: bool = False) -> dict[str, str]:
    headers = {"Accept": "application/json"}
    if json_body:
        headers["Content-Type"] = "application/json"
    token = _env_text("AI_TTS_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def request_json(
    path: str,
    *,
    method: str = "GET",
    payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    url = f"{_base_url()}/{path.lstrip('/')}"
    body = None
    if payload is not None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib_request.Request(
        url,
        data=body,
        headers=_headers(json_body=payload is not None),
        method=method,
    )
    timeout = _positive_float("AI_TTS_TIMEOUT_SECONDS", DEFAULT_TIMEOUT_SECONDS)

    try:
        with urllib_request.urlopen(req, timeout=timeout) as response:
            raw = response.read()
    except urllib_error.HTTPError as exc:
        detail = exc.read(2000).decode("utf-8", errors="replace").strip()
        raise BridgeError(
            f"AI TTS service returned HTTP {exc.code}: {detail or exc.reason}"
        ) from exc
    except urllib_error.URLError as exc:
        raise BridgeError(f"Cannot reach AI TTS service at {_base_url()}: {exc.reason}") from exc
    except TimeoutError as exc:
        raise BridgeError(f"AI TTS request timed out after {timeout:g} seconds") from exc

    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise BridgeError("AI TTS service returned malformed JSON") from exc
    if not isinstance(decoded, dict):
        raise BridgeError("AI TTS service returned a non-object JSON response")
    return decoded


def decode_audio_response(payload: dict[str, Any]) -> tuple[bytes, dict[str, Any]]:
    encoded = payload.get("audio_base64")
    if not isinstance(encoded, str) or not encoded:
        raise BridgeError("AI TTS response is missing audio_base64")
    try:
        audio = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise BridgeError("AI TTS response contains invalid base64 audio") from exc

    limit = _positive_int("AI_TTS_MAX_AUDIO_BYTES", DEFAULT_MAX_AUDIO_BYTES)
    if not audio:
        raise BridgeError("AI TTS service returned empty audio")
    if len(audio) > limit:
        raise BridgeError(
            f"AI TTS audio is {len(audio)} bytes, exceeding AI_TTS_MAX_AUDIO_BYTES={limit}"
        )

    extension = str(payload.get("audio_extension") or "").lower()
    media_type = str(payload.get("media_type") or "").lower()
    if extension != "wav" or media_type != "audio/wav":
        raise BridgeError(
            "AI TTS bridge requested WAV but the service returned "
            f"{media_type or 'unknown media type'} / {extension or 'unknown extension'}"
        )
    if len(audio) < 12 or audio[:4] != b"RIFF" or audio[8:12] != b"WAVE":
        raise BridgeError("AI TTS service returned an invalid WAV container")
    return audio, payload


def atomic_write(path: Path, content: bytes) -> Path:
    target = path.expanduser().resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{target.name}.",
        suffix=".tmp",
        dir=target.parent,
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, target)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise
    return target


def default_output_path() -> Path:
    fd, name = tempfile.mkstemp(
        prefix="local-voicemode-ai-",
        suffix=".wav",
        dir=os.getenv("TMPDIR") or "/tmp",
    )
    os.close(fd)
    Path(name).unlink(missing_ok=True)
    return Path(name)


def synthesize(text: str, language: str, output: Path | None) -> tuple[Path, dict[str, Any]]:
    provider = normalize_provider(_env_text("AI_TTS_PROVIDER") or "xai")
    payload = build_process_payload(
        text,
        provider=provider,
        source_language=language or "auto",
    )
    response = request_json("/api/process/json", method="POST", payload=payload)
    audio, metadata = decode_audio_response(response)
    target = atomic_write(output or default_output_path(), audio)
    return target, metadata


def print_catalog(kind: str, provider: str | None) -> None:
    if kind == "providers":
        payload = request_json("/api/providers")
    elif kind == "health":
        payload = request_json("/health")
    else:
        resolved = normalize_provider(provider or _env_text("AI_TTS_PROVIDER") or "xai")
        payload = request_json(f"/api/{kind}?provider={resolved}")
    print(json.dumps(payload, ensure_ascii=False, indent=2, default=str))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Bridge Local VoiceMode LLM to a local AI Sentence Tagger or AI Voice Studio "
            "service for provider-correct xAI / Google Gemini speech."
        )
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    synth = subparsers.add_parser("synthesize", help="Tag and synthesize one utterance")
    synth.add_argument("--text", required=True)
    synth.add_argument("--language", default="auto")
    synth.add_argument("--output", type=Path)
    synth.add_argument(
        "--metadata",
        action="store_true",
        help="Write response metadata to stderr; stdout remains the audio path",
    )

    subparsers.add_parser("providers", help="Print provider catalog")
    subparsers.add_parser("health", help="Print companion-service health")
    for name in ("voices", "tags", "audio-formats"):
        command = subparsers.add_parser(name, help=f"Print {name} catalog")
        command.add_argument("--provider")

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "synthesize":
            path, metadata = synthesize(args.text, args.language, args.output)
            if args.metadata:
                safe = {
                    key: metadata.get(key)
                    for key in (
                        "provider",
                        "voice_id",
                        "language",
                        "output_format",
                        "media_type",
                        "audio_extension",
                        "audio_bytes",
                    )
                }
                print(json.dumps(safe, ensure_ascii=False, default=str), file=sys.stderr)
            print(path)
        elif args.command in {"providers", "health"}:
            print_catalog(args.command, None)
        else:
            print_catalog(args.command, args.provider)
    except BridgeError as exc:
        print(f"ai-tts-provider: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("ai-tts-provider: interrupted", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
