"""Focused regression tests for VAD recorder buffer/sample accounting."""

from __future__ import annotations

import importlib.util
import sys
import types
from pathlib import Path

import numpy as np


# vad_recorder imports optional runtime packages at module import time. Stub the
# hardware/model-specific pieces so the pure buffering logic is testable in CI.
sounddevice = types.ModuleType("sounddevice")
sounddevice.CallbackStop = RuntimeError
ns = types.SimpleNamespace(device=(None, None))
sounddevice.default = ns
sounddevice.query_devices = lambda *_args, **_kwargs: []
sounddevice.InputStream = object
sounddevice.sleep = lambda _ms: None
sys.modules.setdefault("sounddevice", sounddevice)

torch = types.ModuleType("torch")
torch.from_numpy = lambda value: value
sys.modules.setdefault("torch", torch)

silero_vad = types.ModuleType("silero_vad")
silero_vad.VADIterator = object
silero_vad.load_silero_vad = lambda: object()
sys.modules.setdefault("silero_vad", silero_vad)

MODULE_PATH = Path(__file__).parents[1] / "service" / "vad_recorder.py"
spec = importlib.util.spec_from_file_location("vad_recorder", MODULE_PATH)
assert spec and spec.loader
vad_recorder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vad_recorder)
RingBuffer = vad_recorder.RingBuffer


def frame(value: float, length: int = 4) -> np.ndarray:
    return np.full(length, value, dtype=np.float32)


def test_eviction_preserves_absolute_sample_coordinates() -> None:
    ring = RingBuffer(capacity_frames=2)
    ring.append(frame(1))
    ring.append(frame(2))
    ring.append(frame(3))

    assert ring.first_sample == 4
    assert ring.end_sample == 12
    np.testing.assert_array_equal(ring.slice(4, 12), np.concatenate([frame(2), frame(3)]))


def test_slice_clamps_to_retained_window() -> None:
    ring = RingBuffer(capacity_frames=2)
    ring.append(frame(1))
    ring.append(frame(2))
    ring.append(frame(3))

    np.testing.assert_array_equal(ring.slice(0, 8), frame(2))
    np.testing.assert_array_equal(ring.slice(10, 99), frame(3)[2:])


def test_clear_resets_coordinate_space() -> None:
    ring = RingBuffer(capacity_frames=1)
    ring.append(frame(1))
    ring.clear()
    ring.append(frame(9, length=2))

    assert ring.first_sample == 0
    assert ring.end_sample == 2
    np.testing.assert_array_equal(ring.slice(0, 2), frame(9, length=2))


def test_invalid_capacity_is_rejected() -> None:
    try:
        RingBuffer(capacity_frames=0)
    except ValueError:
        pass
    else:
        raise AssertionError("zero-capacity buffers must be rejected")
