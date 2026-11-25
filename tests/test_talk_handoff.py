"""Exercise the Unix talk CLI with fake audio and transcription."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import textwrap

import pytest


@pytest.fixture
def talk(tmp_path):
    shutil.copy(Path(__file__).parents[1] / "service" / "talk.sh", tmp_path)

    def stub(name, source):
        path = tmp_path / name
        path.write_text(textwrap.dedent(source).lstrip())
        path.chmod(0o755)

    stub("tts.sh", """
        touch reply.wav
        printf '%s\\n' reply.wav
    """)
    stub("vad_recorder.py", """
        import json, os, signal, sys, time
        from pathlib import Path

        active = False
        def activate(*args):
            global active
            active = True
            with open("events", "a") as log:
                print("activate", file=log)

        signal.signal(signal.SIGUSR1, activate)
        if "--wait-for-activation" in sys.argv and os.getenv("FAIL_STANDBY"):
            sys.exit(1)
        time.sleep(0.25)
        with open("events", "a") as log:
            print("mic ready", file=log)
        print(json.dumps({"event": "listening"}), flush=True)
        if "--wait-for-activation" in sys.argv:
            deadline = time.monotonic() + 4
            while not active and time.monotonic() < deadline:
                time.sleep(0.01)
            assert active
        Path("capture.wav").write_bytes(b"stub audio")
        print(json.dumps({"event": "speech_end", "file": "capture.wav"}))
    """)
    stub("ffplay", """
        #!/usr/bin/env bash
        printf '%s\\n' "${@: -1}" >> events
    """)
    shutil.copy(tmp_path / "ffplay", tmp_path / "afplay")
    stub("curl", """
        #!/usr/bin/env python3
        import json, os, sys
        from pathlib import Path

        Path(sys.argv[sys.argv.index("-o") + 1]).write_text(
            json.dumps({"text": os.environ["TRANSCRIPT"]})
        )
        print("200", end="")
    """)
    (tmp_path / "beep.wav").touch()

    def run(mode, transcript, **overrides):
        args = ["speak", "Hello", "en"] if mode == "speak" else ["listen"]
        result = subprocess.run(
            ["bash", "talk.sh", *args], cwd=tmp_path, text=True,
            capture_output=True, timeout=10,
            env={
                "PATH": f"{tmp_path}{os.pathsep}{os.environ['PATH']}",
                "HOME": str(tmp_path), "PYTHON": sys.executable,
                "TTS_SH": str(tmp_path / "tts.sh"), "TALK_BEEP_FILE": "beep.wav",
                "TALK_AUDIO_LOCK": str(tmp_path / "audio.lock"),
                "TALK_BUS_LOG": "0", "TALK_AUDIO_ARCHIVE": "0",
                "TALK_PRE_RECORD": "1",
                "STT_ENGINE": "local", "TALK_STOP_PHRASES": "stop talk|terminar la conversación",
                "TRANSCRIPT": transcript, **overrides,
            },
        )
        assert result.returncode == 0, result.stderr
        return result.stdout.strip(), (tmp_path / "events").read_text().splitlines()

    return run


def test_delayed_mic_is_ready_before_playback_and_activates_after_cue(talk):
    text = "As soon as you stop talking to me, I should be able to reply."
    assert talk("speak", text) == (text, ["mic ready", "reply.wav", "beep.wav", "activate"])


def test_failed_pre_record_still_plays_reply_then_listens(talk):
    assert talk("speak", "Next turn", FAIL_STANDBY="1") == (
        "Next turn", ["reply.wav", "mic ready", "beep.wav"],
    )


def test_stop_command_matches_full_utterance_with_punctuation(talk):
    assert talk("listen", "¡TERMINAR LA CONVERSACIÓN!") == (
        "__TALK_STOP__", ["mic ready", "beep.wav"],
    )
