# Benchmark results

- **Host CPU:** 12th Gen Intel(R) Core(TM) i7-12700KF
- **Mode:** CPU only, no GPU
- **Voice:** F4 · **Runs:** 5 (median)
- **Date:** 2026-06-11 09:33 UTC

**Silero VAD:** 0.092 ms per 512-sample frame (32 ms of audio) — ~347× realtime

### Parakeet STT
| Utterance | Audio | Latency (median) | RTF | Speed |
|-----------|-------|------------------|-----|-------|
| short (10 words) | 2.42s | 307 ms | 0.127 | 7.9× |
| medium (22 words) | 6.55s | 441 ms | 0.067 | 14.9× |
| long (45 words) | 13.42s | 729 ms | 0.054 | 18.4× |

### Supertonic 3 TTS
| Reply | Audio | Normal (8 steps) | RTF | High (20 steps) | RTF |
|-------|-------|------------------|-----|-----------------|-----|
| short (10 words) | 2.42s | 1386 ms | 0.572 | 2460 ms | 1.015 |
| medium (22 words) | 6.55s | 2505 ms | 0.383 | 5690 ms | 0.869 |
| long (45 words) | 13.42s | 5178 ms | 0.386 | 10194 ms | 0.759 |

_RTF = synthesis time ÷ audio duration (lower is faster; <1.0 is faster than realtime)._
