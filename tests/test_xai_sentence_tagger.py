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
    def test_tag_allowlist_matches_xai_reference_checked_2026_10_28(self):
        # Official TTS guide and REST voice reference, retrieved through Context7.
        self.assertEqual(set(module.XAI_INLINE_TAGS), {
            "pause", "long-pause", "hum-tune", "laugh", "chuckle", "giggle", "cry",
            "tsk", "tongue-click", "lip-smack", "breath", "inhale", "exhale", "sigh",
        })
        self.assertEqual(set(module.XAI_WRAPPING_TAGS), {
            "soft", "whisper", "loud", "build-intensity", "decrease-intensity",
            "higher-pitch", "lower-pitch", "slow", "fast", "sing-song", "singing", "emphasis",
        })

    def test_documented_nested_phrase_styles_and_inline_placement_are_valid(self):
        for original, tagged in (
            ("Goodnight, sleep well.", "<slow><soft>Goodnight, sleep well.</soft></slow>"),
            ("Wait, here it is.", "Wait,[pause] here it is."),
        ):
            with self.subTest(tagged=tagged):
                errors, tags = module.validate_tagged_sentence(original, tagged)
                self.assertEqual(errors, [])
                self.assertTrue(tags)

    def test_unsupported_or_empty_directions_are_rejected(self):
        for tagged in (
            "<laugh-speak>Hello.</laugh-speak>",
            "[cheerfully]Hello.",
            "[soft]Hello.",
            "<laugh>Hello.</laugh>",
            "<soft></soft>Hello.",
            "Hello.<soft> </soft>",
        ):
            with self.subTest(tagged=tagged):
                errors, _ = module.validate_tagged_sentence("Hello.", tagged)
                self.assertTrue(errors)

    def test_neutral_fallback_does_not_cycle_sound_effects_by_sentence_index(self):
        text = "The report is ready."
        first = module.deterministic_tag(text, 0).tagged_text
        for index in range(1, 8):
            with self.subTest(index=index):
                result = module.deterministic_tag(text, index)
                self.assertEqual(result.tagged_text, first)
                self.assertFalse(set(result.tags) & set(module.XAI_INLINE_TAGS))

    def test_mentioning_laughter_does_not_insert_a_laugh_sound(self):
        result = module.deterministic_tag("The log contains the word funny.", 0)
        self.assertNotIn("chuckle", result.tags)

    def test_fallback_styles_only_explicit_delivery_requests(self):
        for text, tag in (
            ("  Please whisper this part.\n", "whisper"),
            ("Por favor, hablá despacio.", "slow"),
            ("The alert says urgent!", "emphasis"),
            ("Is this a secret?", "emphasis"),
        ):
            with self.subTest(text=text):
                result = module.deterministic_tag(text, 0)
                self.assertEqual(result.tags, (tag,))
                self.assertEqual(module.validate_tagged_sentence(text, result.tagged_text)[0], [])

    def test_outdated_llm_tags_are_repaired_but_documented_nested_styles_survive(self):
        response = {"choices": [{"message": {"content": json.dumps({"sentences": [
            {"index": 0, "tagged_text": "<laugh-speak>Hello.</laugh-speak>"},
            {"index": 1, "tagged_text": " <soft></soft>Goodbye."},
            {"index": 2, "tagged_text": " <slow><soft>Sleep well.</soft></slow>"},
        ]})}}]}
        with patch.dict(os.environ, {"TTS_TAGGER_URL": "http://127.0.0.1:12434", "TTS_TAGGER_MODEL": "test"}, clear=True), patch.object(
            module.urllib_request, "urlopen", return_value=FakeResponse(response)
        ):
            result = module.tag_text("Hello. Goodbye. Sleep well.", "en", "llm")
        self.assertEqual([row["source"] for row in result["sentences"]], ["deterministic", "deterministic", "llm"])
        self.assertEqual(result["tagged_sentence_count"], 3)
        self.assertEqual(result["untagged_sentence_indexes"], [])
        self.assertEqual(result["sentences"][2]["tags"], ["slow", "soft"])

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
