"""Exercise the real public adapter with a synthetic engine; no speech claims."""
import importlib.util
import io
from pathlib import Path
from types import SimpleNamespace
import wave

import numpy as np
import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('public_tts', ROOT/'service/supertonic_server.py')
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


class Engine:
    sample_rate = 24000
    voice_style_names = [f'{p}{i}' for p in ('F', 'M') for i in range(1, 6)]
    model = SimpleNamespace(**{n: SimpleNamespace(get_providers=lambda: ['CPUExecutionProvider'])
                              for n in ('dp_ort','text_enc_ort','vector_est_ort','vocoder_ort')})

    def get_voice_style(self, voice):
        return voice

    def synthesize(self, text, **kwargs):
        self.called = (text, kwargs)
        return np.zeros(2400), np.array([0.1])


@pytest.mark.parametrize('field', ['lang', 'lang_code'])
def test_fields_reach_engine_and_return_parseable_wav(field):
    engine = Engine()
    with TestClient(adapter.create_app(lambda: engine)) as client:
        result = client.post('/v1/audio/speech', json={'input':'Hola "amigo"\n', 'voice':'M5',
            field:'es','total_steps':12,'speed':1.2,'response_format':'wav','stream':False})
        assert result.status_code == 200
        assert engine.called == ('Hola "amigo"\n', {'voice_style':'M5','lang':'es','speed':1.2,'total_steps':12})
        with wave.open(io.BytesIO(result.content)) as wav:
            assert wav.getnframes() == 2400
            assert wav.getframerate() == 24000
        for path in ('/health','/healthz'):
            health = client.get(path)
            assert health.status_code == 200
            assert health.json()['backend'] == 'cpu'
            assert health.json()['voices_loaded'] == 10
            assert len(health.json()['session_providers']) == 4
    assert client.get('/health').status_code == 503


@pytest.mark.parametrize('update, status', [({'lang':'es','lang_code':'en'},422),
    ({'lang':'bogus'},400),({'voice':'../file'},400),({'stream':True},400),
    ({'response_format':'mp3'},400),({'speed':0},422),({'total_steps':0},422),
    ({'model':'supertonic-2'},400),({'typo':1},422)])
def test_invalid_requests_fail_before_synthesis(update, status):
    engine=Engine()
    with TestClient(adapter.create_app(lambda:engine)) as client:
        assert client.post('/v1/audio/speech',json={'input':'hello',**update}).status_code == status
        assert not hasattr(engine,'called')


@pytest.mark.parametrize('audio', [np.array([]),np.array([float('nan')]),np.array([float('inf')])])
def test_invalid_audio_is_not_success(audio):
    engine=Engine()
    engine.synthesize=lambda *a, **kw:(audio,0)
    with TestClient(adapter.create_app(lambda:engine)) as client:
        assert client.post('/v1/audio/speech',json={'input':'hello'}).status_code == 500


def test_health_reports_actual_mixed_sessions():
    engine=Engine()
    engine.model=SimpleNamespace(**{n:SimpleNamespace(get_providers=lambda:['CUDAExecutionProvider','CPUExecutionProvider'])
            for n in ('dp_ort','text_enc_ort','vector_est_ort','vocoder_ort')})
    engine.model.vocoder_ort=SimpleNamespace(get_providers=lambda:['CPUExecutionProvider'])
    assert adapter.runtime_health(engine)['backend'] == 'mixed'


@pytest.mark.parametrize('backend',['mlx','coreml','typo','cuda'])
def test_unavailable_backend_fails_explicitly(monkeypatch,backend):
    import onnxruntime
    monkeypatch.setenv('SUPERTONIC_ORT_BACKEND',backend)
    monkeypatch.setattr(onnxruntime,'get_available_providers',lambda:['CPUExecutionProvider'])
    with pytest.raises(RuntimeError):
        adapter.load_engine()

@pytest.mark.parametrize('client_name',['tts.sh','tts_backends.sh'])
def test_shell_client_serializes_public_fields_without_bad_json(tmp_path,client_name):
    import os, subprocess, json
    source=(ROOT/'service'/client_name).read_text()
    start=source.index('speak_supertonic() {')
    end=source.index('\n}\n',start)+3
    fake=tmp_path/'curl'
    fake.write_text('''#!/usr/bin/env python3
import sys, pathlib, os
args=sys.argv[1:]
pathlib.Path(os.environ['PAYLOAD']).write_text(args[args.index('-d')+1])
pathlib.Path(args[args.index('-o')+1]).write_bytes(b'RIFFfake')
print('200',end='')
''')
    fake.chmod(0o755)
    env=dict(os.environ,PATH=str(tmp_path)+os.pathsep+os.environ['PATH'],PAYLOAD=str(tmp_path/'payload'))
    script=source[start:end]+'''\nSUPERTONIC_VOICE=M5
SUPERTONIC_STEPS=12
SUPERTONIC_SPEED=1.2
TTS_QUALITY=high
SUPERTONIC_URL=http://127.0.0.1:8766
TTS_NO_PLAY=1
OUTPUT="$1"
speak_supertonic "$2" es
'''
    subprocess.run(['bash','-c',script,'test',str(tmp_path/'wav'),'Hola "capo"\n\\'],env=env,check=True,capture_output=True)
    payload=json.loads((tmp_path/'payload').read_text())
    assert payload == {'model':'supertonic-3','input':'Hola "capo"\n\\','voice':'M5',
                       'response_format':'wav','stream':False,'total_steps':12,'speed':1.2,'lang':'es'}
