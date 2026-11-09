"""Exercise playback/capture ordering through the talk CLI without audio hardware."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import textwrap

import pytest


ROOT = Path(__file__).resolve().parents[1]


def executable(path, source):
    path.write_text(textwrap.dedent(source).lstrip())
    path.chmod(0o755)


@pytest.fixture
def talk(tmp_path):
    shutil.copy(ROOT / "service/talk.sh", tmp_path / "talk.sh")
    (tmp_path / "tts_lang.sh").write_text("")
    log = tmp_path / "events"
    env = {
        "HOME": str(tmp_path),
        "PATH": str(tmp_path) + os.pathsep + os.environ["PATH"],
        "PYTHON": sys.executable,
        "TTS_SH": str(tmp_path / "tts.sh"),
        "TTS_LANG_SH": str(tmp_path / "tts_lang.sh"),
        "EVENTS": str(log),
        "TEST_WAV": str(tmp_path / "reply.wav"),
        "TALK_AUDIO_LOCK": str(tmp_path / "audio.lock"),
        "TALK_AUDIO_ARCHIVE": "0",
        "TALK_BUS_LOG": "0",
        "TALK_READY_CUE": "0",
        "TALK_BEEP": "0",
        "MIC_QUERY": "Bluetooth microphone",
        "SUPERTONIC_VOICE": "F4",
        "SUPERTONIC_STEPS": "20",
    }
    executable(tmp_path / "tts.sh", """
        #!/usr/bin/env bash
        printf 'tts:%s:%s:%s\\n' "$TTS_ENGINE" "$SUPERTONIC_VOICE" "$SUPERTONIC_STEPS" >> "$EVENTS"
        [ "${FAIL_TTS:-0}" = 1 ] && exit 1
        if [ "${TTS_NO_PLAY:-0}" = 1 ]; then
            printf RIFF > "$TEST_WAV"
            printf '%s\\n' "$TEST_WAV"
        else
            printf 'playback-start\\nplayback-end\\n' >> "$EVENTS"
        fi
    """)
    executable(tmp_path / "ffplay", """
        #!/usr/bin/env python3
        import os, pathlib, time
        log = pathlib.Path(os.environ['EVENTS'])
        # The opt-in path starts the recorder concurrently; wait for its startup.
        deadline = time.monotonic() + 2
        while 'recorder-open' not in log.read_text() and time.monotonic() < deadline:
            time.sleep(.01)
        with log.open('a') as stream:
            stream.write('playback-start\\nplayback-end\\n')
    """)
    executable(tmp_path / "vad_recorder.py", """
        import json, os, pathlib, signal, sys, time
        args = sys.argv[1:]
        activated = False
        def activate(*_args):
            global activated
            activated = True
        signal.signal(signal.SIGUSR1, activate)
        with open(os.environ['EVENTS'], 'a') as stream:
            stream.write('recorder-open\\n')
        if args[args.index('--ready-delay-ms') + 1] == '600000':
            deadline = time.monotonic() + 3
            while not activated and time.monotonic() < deadline:
                time.sleep(.01)
            assert activated, 'pre-record handoff did not activate recorder'
        output = pathlib.Path(args[args.index('--output-file') + 1])
        output.write_bytes(b'RIFF')
        print(json.dumps({'event': 'speech_end', 'file': str(output)}))
    """)
    executable(tmp_path / "curl", """
        #!/usr/bin/env python3
        import json, os, pathlib, sys
        args = sys.argv[1:]
        with open(os.environ['EVENTS'], 'a') as stream:
            stream.write('transcribe\\n')
        pathlib.Path(args[args.index('-o') + 1]).write_text(json.dumps({'text': 'Next turn'}))
        print('200', end='')
    """)

    def run(**overrides):
        completed = subprocess.run(
            ["bash", str(tmp_path / "talk.sh"), "speak", "Hello", "en"],
            env={**env, **overrides}, cwd=tmp_path, capture_output=True,
            text=True, timeout=10,
        )
        assert completed.returncode == 0, completed.stderr
        return completed, log.read_text().splitlines()

    return run


def test_default_finishes_local_playback_before_opening_mic(talk):
    result, events = talk()
    assert events == ["tts:supertonic:F4:20", "playback-start", "playback-end",
                      "recorder-open", "transcribe"]
    assert result.stdout.strip() == "Next turn"


@pytest.mark.skipif(os.name == "nt", reason="Unix signal handoff")
def test_pre_record_remains_available_as_explicit_opt_in(talk):
    result, events = talk(TALK_PRE_RECORD="1")
    assert events == ["tts:supertonic:F4:20", "recorder-open", "playback-start",
                      "playback-end", "transcribe"]
    assert result.stdout.strip() == "Next turn"


@pytest.mark.parametrize("pre_record", ["0", "1"])
def test_read_aloud_never_opens_mic(talk, pre_record):
    result, events = talk(TALK_AUTO_LISTEN="0", TALK_PRE_RECORD=pre_record)
    assert events == ["tts:supertonic:F4:20", "playback-start", "playback-end"]
    assert result.stdout == ""


def test_failed_tts_keeps_listening(talk):
    result, events = talk(FAIL_TTS="1")
    assert events == ["tts:supertonic:F4:20", "recorder-open", "transcribe"]
    assert result.stdout.strip() == "Next turn"


def test_explicit_engine_selection_is_preserved(talk):
    _, events = talk(TTS_ENGINE="xai", TALK_AUTO_LISTEN="0")
    assert events[0] == "tts:xai:F4:20"


def test_standalone_tts_defaults_to_local_supertonic(tmp_path):
    executable(tmp_path / "curl", """
        #!/usr/bin/env python3
        import json, os, pathlib, sys
        args = sys.argv[1:]
        assert 'http://127.0.0.1:8766/v1/audio/speech' in args
        payload = json.loads(args[args.index('-d') + 1])
        assert payload['voice'] == 'F4'
        assert payload['total_steps'] == 20
        pathlib.Path(args[args.index('-o') + 1]).write_bytes(b'RIFFtest')
        print('200', end='')
    """)
    result = subprocess.run(
        ["bash", str(ROOT / "service/tts.sh"), "Hello", "en"],
        env={"HOME": str(tmp_path), "PATH": str(tmp_path) + os.pathsep + os.environ["PATH"],
             "TTS_LANG_SH": str(ROOT / "service/tts_lang.sh"),
             "TTS_OUTPUT": str(tmp_path / "reply.wav"),
             "TTS_NO_PLAY": "1", "SUPERTONIC_STEPS": "20"},
        capture_output=True, text=True, timeout=10,
    )
    assert result.returncode == 0, result.stderr
    output = Path(result.stdout.strip())
    try:
        assert output.read_bytes() == b"RIFFtest"
    finally:
        output.unlink(missing_ok=True)
