from __future__ import annotations

import base64
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "integrations"
    / "ai-sentence-tagger"
    / "tts_provider.py"
)
SPEC = importlib.util.spec_from_file_location("ai_tts_provider", MODULE_PATH)
assert SPEC and SPEC.loader
provider = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = provider
SPEC.loader.exec_module(provider)


def wav_bytes() -> bytes:
    return (
        b"RIFF"
        + (36).to_bytes(4, "little")
        + b"WAVE"
        + b"fmt "
        + (16).to_bytes(4, "little")
        + (1).to_bytes(2, "little")
        + (1).to_bytes(2, "little")
        + (24000).to_bytes(4, "little")
        + (48000).to_bytes(4, "little")
        + (2).to_bytes(2, "little")
        + (16).to_bytes(2, "little")
        + b"data"
        + (0).to_bytes(4, "little")
    )


def valid_tagging() -> dict:
    return {
        "sentence_count": 2,
        "tagged_sentence_count": 2,
        "untagged_sentence_indexes": [],
        "annotations": [
            {
                "index": 0,
                "original": "Hello.",
                "tagged_text": "<soft>Hello.</soft>",
            },
            {
                "index": 1,
                "original": " Goodbye.",
                "tagged_text": " <emphasis>Goodbye.</emphasis>",
            },
        ],
    }


class FakeResponse:
    def __init__(self, payload: dict):
        self.payload = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return None

    def read(self):
        return self.payload


class ProviderBridgeTests(unittest.TestCase):
    def test_provider_aliases(self):
        self.assertEqual(provider.normalize_provider("gemini"), "google")
        self.assertEqual(provider.normalize_provider("GROK"), "xai")
        with self.assertRaises(provider.BridgeError):
            provider.normalize_provider("unknown")

    def test_google_payload_uses_provider_native_wav_and_annotations(self):
        with patch.dict(os.environ, {}, clear=True):
            payload = provider.build_process_payload(
                "Hello.", provider="gemini", source_language="en"
            )
        self.assertEqual(payload["provider"], "google")
        self.assertEqual(
            payload["output_format"],
            {"codec": "wav", "sample_rate": 24000, "bit_rate": None},
        )
        self.assertEqual(payload["coverage_mode"], "natural")
        self.assertEqual(payload["tts_language"], "en")
        self.assertIs(payload["include_annotations"], True)

    def test_xai_payload_uses_wav_for_voicemode(self):
        with patch.dict(
            os.environ,
            {
                "AI_TTS_VOICE": "EVE",
                "AI_TTS_LANGUAGE": "auto",
                "AI_TTS_STYLE_PROMPT": "Ignored by xAI transport",
            },
            clear=True,
        ):
            payload = provider.build_process_payload(
                "Hello.", provider="xai", source_language="en"
            )
        self.assertEqual(payload["provider"], "xai")
        self.assertEqual(payload["voice_id"], "EVE")
        self.assertEqual(payload["output_format"]["sample_rate"], 48000)
        self.assertEqual(payload["output_format"]["codec"], "wav")
        self.assertIs(payload["include_annotations"], True)

    def test_sentence_invariant_accepts_complete_annotations(self):
        self.assertEqual(
            provider.validate_sentence_tagging_response({"tagging": valid_tagging()}),
            {"sentence_count": 2, "tagged_sentence_count": 2},
        )

    def test_sentence_invariant_rejects_missing_or_untagged_rows(self):
        bad = valid_tagging()
        bad["tagged_sentence_count"] = 1
        bad["untagged_sentence_indexes"] = [1]
        with self.assertRaisesRegex(provider.BridgeError, "invariant failed"):
            provider.validate_sentence_tagging_response({"tagging": bad})

        bad = valid_tagging()
        bad["annotations"][1]["tagged_text"] = bad["annotations"][1]["original"]
        with self.assertRaisesRegex(provider.BridgeError, "has no inserted speech tag"):
            provider.validate_sentence_tagging_response({"tagging": bad})

        bad = valid_tagging()
        bad["annotations"] = bad["annotations"][:1]
        with self.assertRaisesRegex(provider.BridgeError, "complete per-sentence"):
            provider.validate_sentence_tagging_response({"tagging": bad})

    def test_rejects_non_wav_override(self):
        with patch.dict(os.environ, {"AI_TTS_CODEC": "mp3"}, clear=True):
            with self.assertRaisesRegex(provider.BridgeError, "requires WAV"):
                provider.build_process_payload(
                    "Hello.", provider="xai", source_language="en"
                )

    def test_strict_audio_decode(self):
        audio = wav_bytes()
        decoded, metadata = provider.decode_audio_response(
            {
                "audio_base64": base64.b64encode(audio).decode(),
                "audio_extension": "wav",
                "media_type": "audio/wav",
            }
        )
        self.assertEqual(decoded, audio)
        self.assertEqual(metadata["audio_extension"], "wav")
        with self.assertRaisesRegex(provider.BridgeError, "invalid base64"):
            provider.decode_audio_response(
                {
                    "audio_base64": "%%%",
                    "audio_extension": "wav",
                    "media_type": "audio/wav",
                }
            )

    def test_atomic_write(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "speech.wav"
            result = provider.atomic_write(target, wav_bytes())
            self.assertEqual(result, target.resolve())
            self.assertEqual(target.read_bytes(), wav_bytes())
            self.assertFalse(list(target.parent.glob(".speech.wav.*.tmp")))

    def test_request_json_uses_companion_api_and_token(self):
        captured = {}

        def fake_urlopen(req, timeout):
            captured["url"] = req.full_url
            captured["timeout"] = timeout
            captured["authorization"] = req.headers.get("Authorization")
            captured["body"] = json.loads(req.data)
            return FakeResponse({"ok": True})

        with patch.dict(
            os.environ,
            {
                "AI_TTS_URL": "http://127.0.0.1:9000/",
                "AI_TTS_TOKEN": "secret-token",
                "AI_TTS_TIMEOUT_SECONDS": "9",
            },
            clear=True,
        ), patch.object(provider.urllib_request, "urlopen", fake_urlopen):
            result = provider.request_json(
                "/api/process/json",
                method="POST",
                payload={"provider": "google"},
            )

        self.assertEqual(result, {"ok": True})
        self.assertEqual(captured["url"], "http://127.0.0.1:9000/api/process/json")
        self.assertEqual(captured["timeout"], 9.0)
        self.assertEqual(captured["authorization"], "Bearer secret-token")
        self.assertEqual(captured["body"]["provider"], "google")

    def test_synthesize_rejects_audio_if_sentence_proof_is_missing(self):
        response = {
            "tagging": {
                "sentence_count": 1,
                "tagged_sentence_count": 0,
                "untagged_sentence_indexes": [0],
                "annotations": [],
            },
            "audio_base64": base64.b64encode(wav_bytes()).decode(),
            "audio_extension": "wav",
            "media_type": "audio/wav",
        }
        with patch.dict(os.environ, {"AI_TTS_PROVIDER": "xai"}, clear=True), patch.object(
            provider, "request_json", return_value=response
        ):
            with self.assertRaises(provider.BridgeError):
                provider.synthesize("Hello.", "en", None)


if __name__ == "__main__":
    unittest.main()
