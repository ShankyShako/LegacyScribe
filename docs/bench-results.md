# STT benchmark results

Produced by `tools/lsbench` on an Apple M5, 24 GB, macOS 26.6.2. Raw JSON (per-run latencies, hypotheses, error counts) is in `~/Library/Application Support/LegacyScribe/bench/`.

## Synthetic voice (`fixtures/say`), 2026-10-06

Four macOS `say` clips, 5 warm runs each, median latency. WER is the corpus WER after lowercasing and stripping punctuation.

| Engine | 1.7 s | 7.7 s | 7.5 s | 23.6 s | Corpus WER | Load (warm) | Peak footprint |
|---|---|---|---|---|---|---|---|
| Cohere 4-bit (MLX) | 133 ms | 364 ms | 266 ms | 681 ms | 4.58% | 0.6 s | 2.4 GB |
| Cohere 8-bit (MLX) | 124 ms | 302 ms | 296 ms | 738 ms | 4.58% | 1.6 s | 3.3 GB |
| Parakeet ultra | 38 ms | 57 ms | 56 ms | 124 ms | 4.58% | n/a | 72 MB* |
| Parakeet v2 | 38 ms | 51 ms | 50 ms | 92 ms | 6.11% | n/a | 75 MB* |
| Parakeet v3 | 37 ms | 56 ms | 55 ms | 123 ms | 6.87% | n/a | 71 MB* |
| Parakeet phonon2 | 31 ms | 56 ms | 55 ms | 122 ms | 10.69% | n/a | 76 MB* |

\*CoreML/ANE memory isn't counted in the process footprint. Parakeet load times (10–33 min) were first-use downloads over a slow link, not model load.

What the numbers say:
- Every engine meets the P0 target (warm 10 s clip under 500 ms). Parakeet is about 5× faster than Cohere.
- Cohere 8-bit buys nothing over 4-bit here: the same transcripts, similar latency, 0.9 GB more memory.
- Most counted errors are formatting the normalizer doesn't fold, not mis-hearings: "stand up" for "standup", "10 30"/"1030"/"10.30" for "10:30", "Swift UI" for "SwiftUI". These are LLM-cleanup territory.
- Every engine heard "is pushed to talk" for "as push to talk", so that is the `say` voice, not the engines.
- Real mis-hearings: v3 and phonon2 heard "fork X" for "fork Hex". phonon2 also skips inverse text normalization ("ten thirty", "M five", "twenty six"), which accounts for its higher WER.

Synthetic speech can't decide the default engine. Next: record `fixtures/me` with `tools/lsbench/record-voice-fixtures.sh` and re-run every engine on it.
