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

Synthetic speech can't decide the default engine; see the real-voice results below.

## Real voice (`fixtures/me`), 2026-10-06

The user's 20 clips from `voice-prompts.txt` (3.7–9.8 s each), 3 warm runs. "Per 10 s" is the median of latency scaled to a 10 s clip.

| Engine | Corpus WER | Median latency | Per 10 s | Peak footprint |
|---|---|---|---|---|
| Cohere 4-bit (MLX) | **5.28%** | 208 ms | 317 ms | 2.0 GB |
| Cohere 8-bit (MLX) | 5.63% | 238 ms | 343 ms | 2.9 GB |
| Parakeet ultra | 8.10% | 48 ms | 74 ms | 50 MB* |
| Parakeet v3 (app default today) | 8.80% | 46 ms | 73 ms | 48 MB* |
| Parakeet phonon2 | 8.80% | 46 ms | 71 ms | 51 MB* |
| Parakeet v2 | 9.15% | 50 ms | 78 ms | 66 MB* |

What the numbers say:
- Cohere 4-bit is the most accurate and stays well inside the 500 ms budget. 8-bit is no better.
- Several "errors" are shared by every engine ("tasks", "want", "performs", "doctor's"), so the speaker said those words and the reference is off. Cohere's remaining errors are mostly formatting ("2 p.m.", "Geometry Neuroscience").
- The gap is jargon. Cohere: "technical depth", "OmniRoot", "Synthing". Parakeet ultra/v3: "weekly sink", "Kohir"/"Kojere" for Cohere, "tail scale", "legacy subscribe", "PostgreSES SQL", and v3's "Quran's cluster" for Kubernetes.
- Every engine misses the user's own proper nouns (OmniRoute, Syncthing). That's the job of the vocabulary list and LLM cleanup (P2/P3).

Recommendation: Cohere 4-bit as the default engine once its adapter lands in P1; Parakeet v3 stays the app default until then and remains the fast fallback.
