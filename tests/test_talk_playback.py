"""Exercise playback/capture ordering through the talk CLI without audio hardware."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import textwrap
import time

import pytest


ROOT = Path(__file__).resolve().parents[1]


def executable(path, source):
    path.write_text(textwrap.dedent(source).lstrip())
    path.chmod(0o755)


@pytest.fixture(params=["Linux", "Darwin"])
def talk(tmp_path, request):
    shutil.copy(ROOT / "service/talk.sh", tmp_path / "talk.sh")
    (tmp_path / "tts_lang.sh").write_text("")
    log = tmp_path / "events"
    log.touch()
    player_log = tmp_path / "players"
    temp_log = tmp_path / "temp-files"
    recorder_pid = tmp_path / "recorder-pid"
    env = {
        "HOME": str(tmp_path),
        "PATH": str(tmp_path) + os.pathsep + os.environ["PATH"],
        "PYTHON": sys.executable,
        "TTS_SH": str(tmp_path / "tts.sh"),
        "TTS_LANG_SH": str(tmp_path / "tts_lang.sh"),
        "EVENTS": str(log),
        "PLAYER_LOG": str(player_log),
        "TEMP_LOG": str(temp_log),
        "RECORDER_PID": str(recorder_pid),
        "READY_SEEN": str(tmp_path / "ready-seen"),
        "REAL_MKTEMP": shutil.which("mktemp"),
        "REAL_GREP": shutil.which("grep"),
        "TEST_WAV": str(tmp_path / "reply.wav"),
        "TALK_BEEP_FILE": str(tmp_path / "beep.wav"),
        "TALK_AUDIO_LOCK": str(tmp_path / "audio.lock"),
        "TALK_AUDIO_ARCHIVE": "0",
        "TALK_BUS_LOG": "0",
        "TALK_READY_CUE": "0",
        "TALK_BEEP": "0",
        "MIC_QUERY": "Bluetooth microphone",
        "SUPERTONIC_VOICE": "F4",
        "SUPERTONIC_STEPS": "20",
    }
    # Exercise the real shell platform branches on either host. All selected
    # players are mocks; these tests make no claim about physical audio devices.
    executable(tmp_path / "uname", f"#!/bin/sh\nprintf '%s\\n' '{request.param}'\n")
    executable(tmp_path / "grep", """
        #!/bin/sh
        "$REAL_GREP" "$@"
        status=$?
        if [ "$status" = 0 ]; then
            case "$*" in *listening*) touch "$READY_SEEN" ;; esac
        fi
        exit "$status"
    """)
    executable(tmp_path / "mktemp", """
        #!/usr/bin/env python3
        import os, subprocess, sys
        path = subprocess.check_output([os.environ['REAL_MKTEMP'], *sys.argv[1:]], text=True)
        with open(os.environ['TEMP_LOG'], 'a') as stream:
            stream.write(path)
        print(path, end='')
    """)
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
        import os, pathlib, sys, time
        log = pathlib.Path(os.environ['EVENTS'])
        with open(os.environ['PLAYER_LOG'], 'a') as stream:
            stream.write(pathlib.Path(sys.argv[0]).name + '\\n')
        with log.open('a') as stream:
            if pathlib.Path(sys.argv[-1]).name == 'beep.wav':
                stream.write('ready-cue\\n')
            else:
                stream.write('playback-start\\n')
                stream.flush()
                if os.getenv('RECORDER_FAIL_DURING_PLAYBACK') == '1':
                    deadline = time.monotonic() + 3
                    while 'recorder-error' not in log.read_text() and time.monotonic() < deadline:
                        time.sleep(.01)
                    assert 'recorder-error' in log.read_text()
                stream.write('playback-end\\n')
        if os.getenv('FAIL_PLAYBACK') == '1':
            sys.exit(1)
    """)
    # Darwin selects afplay; never invoke a real audio player in these tests.
    shutil.copy(tmp_path / "ffplay", tmp_path / "afplay")
    executable(tmp_path / "vad_recorder.py", """
        import json, os, pathlib, signal, sys, time
        args = sys.argv[1:]
        log = pathlib.Path(os.environ['EVENTS'])
        pathlib.Path(os.environ['RECORDER_PID']).write_text(str(os.getpid()))
        if os.getenv('RECORDER_IGNORE_TERM') == '1':
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if os.getenv('RECORDER_MARK_START') == '1':
            with log.open('a') as stream:
                stream.write('recorder-starting\\n')
        if os.getenv('RECORDER_STALL') == '1':
            while True:
                time.sleep(.01)
        time.sleep(float(os.getenv('RECORDER_STARTUP_DELAY', '0')))
        if os.getenv('RECORDER_FAIL') == '1':
            sys.exit(1)
        activated = False
        def activate(*_args):
            global activated
            activated = True
        signal.signal(signal.SIGUSR1, activate)
        with open(os.environ['EVENTS'], 'a') as stream:
            stream.write('recorder-open\\n')
        if os.getenv('RECORDER_READY_ERROR') == '1':
            print(json.dumps({'event': 'listening'}) + '\\n' +
                  json.dumps({'event': 'error', 'message': 'input failed'}), flush=True)
            while True:
                time.sleep(.01)
        print(json.dumps({'event': 'listening'}), flush=True)
        if args[args.index('--ready-delay-ms') + 1] == '600000':
            deadline = time.monotonic() + 3
            while not activated and time.monotonic() < deadline:
                if os.getenv('RECORDER_FAIL_DURING_PLAYBACK') == '1' and 'playback-start' in log.read_text():
                    print(json.dumps({'event': 'error', 'message': 'capture failed'}), flush=True)
                    with log.open('a') as stream:
                        stream.write('recorder-error\\n')
                    sys.exit(2)
                time.sleep(.01)
            assert activated, 'pre-record handoff did not activate recorder'
            with log.open('a') as stream:
                stream.write('recorder-activated\\n')
        elif os.getenv('TALK_READY_CUE') == '1':
            deadline = time.monotonic() + 3
            while 'ready-cue' not in log.read_text() and time.monotonic() < deadline:
                time.sleep(.01)
            assert 'ready-cue' in log.read_text(), 'missing ready cue'
        else:
            # Wait for the CLI to observe readiness rather than racing its poll.
            deadline = time.monotonic() + 3
            while not pathlib.Path(os.environ['READY_SEEN']).exists() and time.monotonic() < deadline:
                time.sleep(.01)
            assert pathlib.Path(os.environ['READY_SEEN']).exists()
        if os.getenv('RECORDER_CAPTURE_FAIL') == '1':
            sys.exit(2)
        if os.getenv('RECORDER_CAPTURE_STALL') == '1':
            while True:
                time.sleep(.01)
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

    def run(expect_success=True, command=("speak", "Hello", "en"), cancel_at=None, **overrides):
        process = subprocess.Popen(
            ["bash", str(tmp_path / "talk.sh"), *command],
            env={**env, **overrides}, cwd=tmp_path, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True,
        )
        try:
            if cancel_at:
                deadline = time.monotonic() + 3
                while cancel_at not in log.read_text() and time.monotonic() < deadline:
                    time.sleep(.01)
                assert cancel_at in log.read_text(), 'recorder never reached cancellation point'
                process.terminate()
            stdout, stderr = process.communicate(timeout=10)
            completed = subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)
            if recorder_pid.exists():
                with pytest.raises(ProcessLookupError):
                    os.kill(int(recorder_pid.read_text()), 0)
            if temp_log.exists():
                assert all(not Path(path).exists() for path in temp_log.read_text().splitlines())
            assert not (tmp_path / "reply.wav").exists()
            assert not (tmp_path / "audio.lock").exists()
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=3)
            if recorder_pid.exists():
                try:
                    os.kill(int(recorder_pid.read_text()), 9)
                except ProcessLookupError:
                    pass
        assert (completed.returncode == 0) == expect_success, completed.stderr
        if player_log.exists():
            expected_player = "afplay" if request.param == "Darwin" else "ffplay"
            assert set(player_log.read_text().splitlines()) == {expected_player}
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
                      "playback-end", "recorder-activated", "transcribe"]
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


def test_ready_cue_waits_for_delayed_microphone_startup(talk):
    result, events = talk(TALK_READY_CUE="1", TALK_BEEP="1", RECORDER_STARTUP_DELAY="0.2")
    assert events == ["tts:supertonic:F4:20", "playback-start", "playback-end",
                      "recorder-open", "ready-cue", "transcribe"]
    assert result.stdout.strip() == "Next turn"


def test_failed_recorder_never_plays_a_ready_cue(talk):
    result, events = talk(expect_success=False, TALK_READY_CUE="1", TALK_BEEP="1", RECORDER_FAIL="1")
    assert events == ["tts:supertonic:F4:20", "playback-start", "playback-end"]
    assert "Recorder failed to become ready" in result.stderr


def test_pre_record_waits_for_startup_before_playback_and_activation(talk):
    result, events = talk(TALK_PRE_RECORD="1", TALK_BEEP="1", RECORDER_STARTUP_DELAY="0.2")
    assert events == ["tts:supertonic:F4:20", "recorder-open", "playback-start",
                      "playback-end", "ready-cue", "recorder-activated", "transcribe"]
    assert result.stdout.strip() == "Next turn"


def test_pre_record_initialization_failure_cleans_up_without_playback(talk):
    _, events = talk(expect_success=False, TALK_PRE_RECORD="1", TALK_BEEP="1", RECORDER_FAIL="1")
    assert events == ["tts:supertonic:F4:20"]


@pytest.mark.parametrize("pre_record", ["0", "1"])
def test_readiness_timeout_stops_even_an_unresponsive_recorder(talk, pre_record):
    result, events = talk(expect_success=False, TALK_PRE_RECORD=pre_record,
                          TALK_READY_TIMEOUT_S="1", RECORDER_STALL="1", RECORDER_IGNORE_TERM="1")
    assert "Recorder failed to become ready" in result.stderr
    assert "recorder-open" not in events
    assert "ready-cue" not in events
    assert "transcribe" not in events


def test_recorder_error_takes_precedence_over_readiness(talk):
    result, events = talk(expect_success=False, TALK_READY_CUE="1", TALK_BEEP="1",
                          RECORDER_READY_ERROR="1")
    assert "Recorder failed to become ready" in result.stderr
    assert "ready-cue" not in events
    assert "transcribe" not in events


@pytest.mark.parametrize("pre_record", ["0", "1"])
def test_capture_failure_is_reported_without_transcription(talk, pre_record):
    result, events = talk(expect_success=False, TALK_PRE_RECORD=pre_record,
                          TALK_READY_CUE="1", TALK_BEEP="1", RECORDER_CAPTURE_FAIL="1")
    assert "Recorder failed during capture" in result.stderr
    assert "transcribe" not in events


def test_pre_record_playback_failure_stops_recorder(talk):
    result, events = talk(expect_success=False, TALK_PRE_RECORD="1", FAIL_PLAYBACK="1")
    assert "Playback failed" in result.stderr
    assert "recorder-activated" not in events
    assert "transcribe" not in events


def test_pre_record_capture_failure_during_playback_suppresses_cue(talk):
    result, events = talk(expect_success=False, TALK_PRE_RECORD="1", TALK_BEEP="1",
                          RECORDER_FAIL_DURING_PLAYBACK="1")
    assert "Recorder failed to become ready" in result.stderr
    assert events == ["tts:supertonic:F4:20", "recorder-open", "playback-start",
                      "recorder-error", "playback-end"]


@pytest.mark.parametrize("pre_record", ["0", "1"])
def test_cancellation_during_startup_stops_recorder(talk, pre_record):
    result, events = talk(expect_success=False, TALK_PRE_RECORD=pre_record,
                          RECORDER_MARK_START="1", RECORDER_STALL="1", cancel_at="recorder-starting")
    assert result.returncode == 143
    assert "ready-cue" not in events
    assert "transcribe" not in events


def test_standalone_listen_cancellation_stops_recorder(talk):
    result, events = talk(expect_success=False, command=("listen",), TALK_READY_CUE="1",
                          TALK_BEEP="1", RECORDER_CAPTURE_STALL="1", cancel_at="ready-cue")
    assert result.returncode == 143
    assert events == ["recorder-open", "ready-cue"]


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
