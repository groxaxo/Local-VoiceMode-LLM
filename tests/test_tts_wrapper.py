from __future__ import annotations

import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "service" / "tts.sh"
TAGGER = ROOT / "service" / "xai_sentence_tagger.py"
SPEC = importlib.util.spec_from_file_location("xai_sentence_tagger_for_wrapper", TAGGER)
assert SPEC and SPEC.loader
TAGGER_MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = TAGGER_MODULE
SPEC.loader.exec_module(TAGGER_MODULE)


class TTSWrapperTests(unittest.TestCase):
    def _fixture(self, backend_exit: int = 1):
        directory = tempfile.TemporaryDirectory()
        root = Path(directory.name)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        payload_path = root / "payload.json"
        backend_log = root / "backend.log"
        curl_log = root / "curl.log"

        backend = root / "tts_backends.sh"
        backend.write_text(
            "#!/usr/bin/env bash\n"
            "printf '%s|%s\\n' \"${TTS_ENGINE:-}\" \"${XAI_API_KEY:-}\" > \"$BACKEND_LOG\"\n"
            f"exit {backend_exit}\n",
            encoding="utf-8",
        )
        backend.chmod(backend.stat().st_mode | stat.S_IXUSR)

        curl = bin_dir / "curl"
        curl.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            "args=sys.argv[1:]\n"
            "out=args[args.index('-o')+1]\n"
            "data_arg=next(a for a in args if a.startswith('@'))\n"
            "payload=json.loads(pathlib.Path(data_arg[1:]).read_text())\n"
            "pathlib.Path(os.environ['PAYLOAD_PATH']).write_text(json.dumps(payload))\n"
            "pathlib.Path(os.environ['CURL_LOG']).write_text('called')\n"
            "wav=(b'RIFF'+(36).to_bytes(4,'little')+b'WAVE'+b'fmt '+"
            "(16).to_bytes(4,'little')+(1).to_bytes(2,'little')+(1).to_bytes(2,'little')+"
            "(48000).to_bytes(4,'little')+(96000).to_bytes(4,'little')+"
            "(2).to_bytes(2,'little')+(16).to_bytes(2,'little')+b'data'+(0).to_bytes(4,'little'))\n"
            "pathlib.Path(out).write_bytes(wav)\n"
            "sys.stdout.write('200')\n",
            encoding="utf-8",
        )
        curl.chmod(curl.stat().st_mode | stat.S_IXUSR)

        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{bin_dir}:{env.get('PATH', '')}",
                "TTS_BACKEND_SH": str(backend),
                "TTS_SENTENCE_TAGGER_PY": str(TAGGER),
                "TTS_NO_PLAY": "1",
                "TTS_TAG_MODE": "deterministic",
                "XAI_API_KEY": "test-key",
                "PAYLOAD_PATH": str(payload_path),
                "BACKEND_LOG": str(backend_log),
                "CURL_LOG": str(curl_log),
            }
        )
        return directory, root, env, payload_path, backend_log, curl_log

    def test_direct_xai_tags_every_sentence_before_request(self):
        fixture, _, env, payload_path, _, curl_log = self._fixture()
        self.addCleanup(fixture.cleanup)
        env["TTS_ENGINE"] = "xai"
        completed = subprocess.run(
            ["bash", str(WRAPPER), "Hello. Are you there?", "en"],
            env=env,
            capture_output=True,
            text=True,
            check=True,
        )
        output = Path(completed.stdout.strip())
        self.assertTrue(output.is_file())
        self.addCleanup(output.unlink, missing_ok=True)
        payload = json.loads(payload_path.read_text())
        spans = TAGGER_MODULE.sentence_spans("Hello. Are you there?")
        self.assertEqual(len(spans), 2)
        self.assertTrue(curl_log.is_file())
        result = TAGGER_MODULE.tag_text("Hello. Are you there?", "en", "deterministic")
        self.assertEqual(payload["text"], result["tagged_text"])
        self.assertEqual(result["tagged_sentence_count"], result["sentence_count"])
        for row in result["sentences"]:
            errors, tags = TAGGER_MODULE.validate_tagged_sentence(
                row["original"], row["tagged_text"]
            )
            self.assertEqual(errors, [])
            self.assertGreaterEqual(len(tags), 1)

    def test_selected_backend_cannot_use_raw_xai_fallback(self):
        fixture, _, env, _, backend_log, curl_log = self._fixture(backend_exit=0)
        self.addCleanup(fixture.cleanup)
        env["TTS_ENGINE"] = "supertonic"
        subprocess.run(
            ["bash", str(WRAPPER), "Hello.", "en"],
            env=env,
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertEqual(backend_log.read_text().strip(), "supertonic|")
        self.assertFalse(curl_log.exists())

    def test_failed_backend_falls_back_to_tagged_xai(self):
        fixture, _, env, payload_path, backend_log, curl_log = self._fixture(backend_exit=1)
        self.addCleanup(fixture.cleanup)
        env["TTS_ENGINE"] = "supertonic"
        completed = subprocess.run(
            ["bash", str(WRAPPER), "One. Two!", "en"],
            env=env,
            capture_output=True,
            text=True,
            check=True,
        )
        output = Path(completed.stdout.strip())
        self.assertTrue(output.is_file())
        self.addCleanup(output.unlink, missing_ok=True)
        self.assertEqual(backend_log.read_text().strip(), "supertonic|")
        self.assertTrue(curl_log.is_file())
        payload = json.loads(payload_path.read_text())
        result = TAGGER_MODULE.tag_text("One. Two!", "en", "deterministic")
        self.assertEqual(payload["text"], result["tagged_text"])
        self.assertEqual(result["tagged_sentence_count"], 2)

    def test_terminal_backend_errors_are_not_hidden_by_xai_fallback(self):
        fixture, _, env, _, backend_log, curl_log = self._fixture(backend_exit=3)
        self.addCleanup(fixture.cleanup)
        env["TTS_ENGINE"] = "inworld"
        completed = subprocess.run(
            ["bash", str(WRAPPER), "Hello.", "en"],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 3)
        self.assertEqual(backend_log.read_text().strip(), "inworld|")
        self.assertFalse(curl_log.exists())

    def test_unknown_engine_is_not_hidden_by_xai_fallback(self):
        fixture, _, env, _, backend_log, curl_log = self._fixture(backend_exit=2)
        self.addCleanup(fixture.cleanup)
        env["TTS_ENGINE"] = "unknown"
        completed = subprocess.run(
            ["bash", str(WRAPPER), "Hello.", "en"],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertEqual(backend_log.read_text().strip(), "unknown|")
        self.assertFalse(curl_log.exists())


if __name__ == "__main__":
    unittest.main()
