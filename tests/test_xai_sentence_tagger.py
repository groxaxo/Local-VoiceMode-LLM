from __future__ import annotations

import importlib.util
import json
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "service" / "xai_sentence_tagger.py"
SPEC = importlib.util.spec_from_file_location("xai_sentence_tagger", MODULE_PATH)
assert SPEC and SPEC.loader
module = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = module
SPEC.loader.exec_module(module)


class FakeResponse:
    def __init__(self, payload: dict):
        self._payload = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return None

    def read(self):
        return self._payload


class SentenceTaggerTests(unittest.TestCase):
    def test_deterministic_mode_tags_every_sentence_and_preserves_source(self):
        text = "Hello.\n\nAre you there? ¡Sí!"
        result = module.tag_text(text, "en", "deterministic")
        self.assertEqual(result["sentence_count"], 3)
        self.assertEqual(result["tagged_sentence_count"], 3)
        self.assertEqual(result["untagged_sentence_indexes"], [])
        self.assertEqual(len(result["sentences"]), 3)
        for row in result["sentences"]:
            errors, tags = module.validate_tagged_sentence(row["original"], row["tagged_text"])
            self.assertEqual(errors, [])
            self.assertGreaterEqual(len(tags), 1)
            self.assertNotEqual(row["original"], row["tagged_text"])

    def test_preserves_abbreviation_as_one_sentence(self):
        spans = module.sentence_spans("Dr. Smith arrived. He waved.")
        self.assertEqual([span.text for span in spans], ["Dr. Smith arrived.", " He waved."])

    def test_llm_valid_rows_are_used_and_invalid_rows_are_repaired(self):
        response = {
            "choices": [
                {
                    "message": {
                        "content": json.dumps(
                            {
                                "sentences": [
                                    {"index": 0, "tagged_text": "<soft>Hello.</soft>"},
                                    {"index": 1, "tagged_text": "Rewritten sentence."},
                                ]
                            }
                        )
                    }
                }
            ]
        }

        def fake_urlopen(req, timeout):
            return FakeResponse(response)

        env = {
            "TTS_TAGGER_URL": "http://127.0.0.1:12434/v1",
            "TTS_TAGGER_MODEL": "local-model",
            "TTS_TAGGER_API_KEY": "not-needed",
        }
        with patch.dict(os.environ, env, clear=True), patch.object(
            module.urllib_request, "urlopen", fake_urlopen
        ):
            result = module.tag_text("Hello. Goodbye.", "en", "llm")

        self.assertEqual(result["sentences"][0]["source"], "llm")
        self.assertEqual(result["sentences"][1]["source"], "deterministic")
        self.assertEqual(result["tagged_sentence_count"], 2)
        for row in result["sentences"]:
            errors, _ = module.validate_tagged_sentence(row["original"], row["tagged_text"])
            self.assertEqual(errors, [])

    def test_auto_mode_falls_back_when_llm_is_not_configured(self):
        with patch.dict(os.environ, {}, clear=True):
            result = module.tag_text("One. Two.", "en", "auto")
        self.assertEqual(result["tagged_sentence_count"], 2)
        self.assertTrue(all(row["source"] == "deterministic" for row in result["sentences"]))

    def test_rejects_unknown_mode_and_blank_text(self):
        with self.assertRaises(module.TaggingError):
            module.tag_text("Hello.", mode="off")
        with self.assertRaises(module.TaggingError):
            module.tag_text("   ", mode="deterministic")


if __name__ == "__main__":
    unittest.main()
