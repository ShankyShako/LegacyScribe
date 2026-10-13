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

## LLM rewrite latency, 2026-10-06

Six real dictations (two of the user's, four constructed), Clean and Prompt modes, called from the Mac. Times include the network round trip over the tailnet.

| Endpoint | Model | Per rewrite | Notes |
|---|---|---|---|
| OmniRoute (CONFORMANT) | `groq/openai/gpt-oss-120b`, reasoning low | 0.6–1.0 s | Best structure: bullets in Prompt mode, keeps questions as questions |
| OmniRoute | `groq/openai/gpt-oss-20b`, reasoning low | 0.4–0.7 s | Slightly looser rewrites |
| Ollama (local) | `qwen3:8b`, thinking off | 0.7–2.6 s; 4.5 s cold | Good cleanup, flatter prompts; once turned a question into a command |
| OmniRoute | `gemini/gemini-3.1-flash-lite`, reasoning none | 3–9 s | Without `reasoning_effort` it spends the token budget thinking and truncates |
| OmniRoute | `gemini/gemini-3-flash-preview`, reasoning minimal | 2.5–22 s | |

Both endpoints fixed mis-hearings from context ("weekly sink" → sync, "post gress SQL" → PostgreSQL) and rewrote a dictated "ignore all previous instructions…" instead of obeying it.

## Read-aloud grading (`calibration/`), 2026-10-10

68 recorded practice lines (594 words), one run each through Cohere 4-bit and Parakeet ultra, v3 and v2 (`lsbench --fixtures …/calibration`), graded by `tools/practice/grade_recordings.py`. Each difference from the script is sorted into one bucket:

- **Formatting:** dropped. Same pronunciation per CMU ("harbour"), digits vs words ("2.4.1"), or split compounds ("Swift UI").
- **New word:** the script word isn't in the CMU dictionary. This is jargon no engine can spell ("Syncthing" heard as "Synsync", "OmniRoute" as "OmniRoot", "Ollama" as "Olama").
- **You said:** 3 or more of the 4 engines heard the same other word at that spot.
- **Sound-alike:** close phonemes, and the engines disagree.
- **Engine error:** everything else.

| Engine | Literal WER | Engine-error WER | You said | New word | Lines ≥95% literal | Lines ≥95% graded |
|---|---|---|---|---|---|---|
| Cohere 4-bit | 2.2% | **0.0%** | 9 | 4 | 59/68 | **68/68** |
| Parakeet ultra | 4.0% | 0.8% | 12 | 6 | 55/68 | 64/68 |
| Parakeet v2 | 4.2% | 1.0% | 12 | 5 | 54/68 | 63/68 |
| Parakeet v3 | 4.9% | 1.3% | 12 | 7 | 50/68 | 60/68 |

What the numbers say:
- Cohere heard every word that was actually said. All of its literal misses were reading or spelling:
  - "equatable" read as "equitable" (a new word to CMU, but every engine heard "equitable")
  - "rebuilding" read as "building", "gathered" as "gather", "twirled" as "twirl"
  - "discussion" read as "discussions", and "transcripts" as "transcript"
  - an extra "feel" in "make mornings feel harder", and an extra "as" in "satisfy hungry workers as well"
- Parakeet's remaining errors are real mishearings: "barked" as "sparked", "merrily" as "merely", a dropped "20128", "Cohere" as "Kohir"/"here", and "SQLite" as "SQL lite".
- **The three Parakeets aren't independent.** They share training and mistakes. In the app, a second opinion therefore has to come from the other family (Cohere and Parakeet). `PracticeGrade` uses that rule, plus `PracticeLine.terms` instead of CMU for new words.
- For fine-tuning (P4.5/P5), a "you said" line has the wrong label for its audio. Redo the line, or relabel it with what was said, before training on it. Otherwise the model learns to hear "equatable" when the speaker said "equitable".

## On-device rewrite (`lsbench rewrite`), 2026-10-10

14 of the user's own dictations from history (8 Clean, 6 Prompt, 1–703 words), using the app's prompts. "Reference" is what `groq/openai/gpt-oss-120b` produced at the time. Peak footprint is for the whole run.

| Model | Load | Clean ≤55 words | Clean 107 / 703 words | Prompt 20 / 132 / 271 words | Speed | Peak |
|---|---|---|---|---|---|---|
| Qwen3 4B Instruct 2507, 4-bit (recommended) | 0.91 s | 0.4–1.5 s | 2.9 s / 12.5 s | 0.9 s / 9.7 s / 12.4 s | ~42 tok/s | 3.7 GB |
| Qwen3 1.7B, 4-bit, thinking off | 0.49 s | 0.2–0.7 s | 1.6 s / 11.3 s | 0.4 s / 1.1 s / 4.1 s | ~90 tok/s | 2.2 GB |

The first 4B run overlapped a model download and ran at ~30 tok/s; the numbers above are from a second run on an idle machine.

What the outputs say:
- **Clean:** close to gpt-oss-120b. It keeps the meaning, removes fillers and is slightly looser ("It's more like three frames per second. No, five…" instead of merging the correction).
- **Prompt:** the structure is right, but it's wordier. It sometimes pads a section with things that weren't said ("ensuring the animation and interaction feel appropriate and accessible"). gpt-oss-120b stays better for Prompt mode.
- **1.7B:** three times faster, but weaker. In Clean it dropped a clause from a 69-word dictation ("like draining the sticker"). In Prompt it mostly returned the dictation lightly tidied instead of structured. It's fine for 8 GB Macs and short Clean dictations.
- The first call includes the Metal warm-up (2.5 s for a 1-word dictation). In the app the model loads while you speak.

## Word timings (`lsbench align`), 2026-10-12

Risk #3: are word timings within ±80 ms? Parakeet TDT's own timings are step-quantized (each word runs from the previous word's end, in 80 ms steps), so they can't serve as ground truth. `lsbench align --tts` builds it instead. Each word of a practice line is synthesized on its own (AVSpeechSynthesizer, en-US), its silence trimmed, and the words joined with 30–250 ms gaps, so every boundary is exact. Isolated words lack coarticulation, but this is still synthetic speech, so expect real voices to do somewhat worse.

TDT rows: 120 practice lines, 879 words. CTC row: the first 60 lines, 398 words. TDT unshifted: the first 60 lines.

| Method | Start: median / p90 / within 80 ms | End: median / p90 / within 80 ms |
|---|---|---|
| CTC forced alignment, Parakeet CTC 110M (`CTCWordAligner`) | 596 ms / 1.67 s / 6% | 613 ms / 1.72 s / 8% |
| Parakeet TDT v2 timings moved onto the words (`WordMatcher`) | 72 ms / 140 ms / 55% (starts 71 ms early) | 91 ms / 194 ms / 42% |
| … with starts shifted +80 ms (**used by the app**) | **51 ms / 113 ms / 77%** | 90 ms / 187 ms / 43% |

- The 110M model's CTC head is blank on every frame (greedy decoding gives nothing), so Viterbi has almost no signal. It squeezes most words into a frame or two. FluidAudio's own docs call it "blank-dominant". The pure-CTC 0.6B is a ~3 GB download, too much for highlighting.
- On 68 of the user's read-aloud recordings, CTC 110M and TDT disagreed by a median 214 ms. Without ground truth, that only says they disagree.
- Timing is ~0.1 s per 10 s of audio (Parakeet), and it runs once per history entry, when it's first played.

## Apple SpeechAnalyzer (`lsbench --engine apple`), 2026-10-12

The 20 real-voice fixtures (`fixtures/me`), one run each, macOS 26.6.2 on the M5:

| Engine | Corpus WER | Latency per clip (6–8 s) | Footprint in the process |
|---|---|---|---|
| Apple SpeechTranscriber (`.transcription` preset, en-US) | 8.80% | ~125–140 ms | 16 MB (macOS hosts the model) |
| Parakeet TDT v2 | 9.15% | ~50 ms | 63 MB |
| Cohere Transcribe 4-bit (2026-10-06 above) | 5.3% | ~320 ms per 10 s | ~1.9 GB while loaded |

It's as accurate as Parakeet on this voice, nearly free in memory, and needs no download in the app (macOS installs the model). That makes it a good choice for 8 GB Macs. Cohere stays the most accurate.

## Notes data safety and memory (`tools/notes-crashtest.py`), 2026-10-12

These runs use the Debug app's headless harness: the real `NotesEngine`, Cohere 4-bit, Silero VAD and the on-device Qwen3 4B notes writer, fed a WAV instead of the microphone. The feed is the 68 read-aloud recordings joined with 1.5–4 s pauses and a minute of room noise (9.5 min), looped for the longer runs.

| Check | Result |
|---|---|
| kill -9 while recording (6 chunks on disk), then relaunch | PASS: those 6 chunks, once each, with the uninterrupted run's text |
| kill -9 while transcribing (20+ chunks queued, fed at 200×) | PASS: all 23 chunks |
| kill -9 while writing notes (no part saved yet) | PASS: notes written after the resume |
| kill -9 after part 1 of 2 was saved (60-min feed, 138 chunks) | PASS: part 1 kept as written, part 2 and notes.md written |
| Chunk 4 fails once, chunk 9 twice (forced Cohere resets) | PASS: chunk 4 matches the reference after the reload; chunk 9 is a gap, its audio kept in `failed/` |
| Peak footprint while transcribing: 9.5 min (23 chunks) vs 2 h 4 min (299 chunks) | **2.13 GB vs 2.24 GB** (by third of the session: 2.18 / 2.16 / 2.24 GB): flat |
| Writing notes for the 2-hour transcript (~23K words) | done, peak 3.99 GB |

The first kill-while-transcribing run failed at the notes step, not on data. The 4B looped to its 8K-token cap on a transcript it had handled fine before (5.6 GB, 3 min). Fixed by a 4K cap per piece and one retry with a repetition penalty.

## Self-correction rule (`lsbench rewrite`, `tools/lsbench/samples/self-correction.jsonl`), 2026-10-12

P3.5 A1. Thirteen samples: 5 Clean self-corrections ("two, no, make it three", "Anna, sorry, I mean Maria", "fifty actually sixty", "scratch that", "the fourth, wait, no, the fifth"), 5 Clean lookalikes where "no", "actually" or "I mean" replaces nothing, and 3 Prompt self-corrections. Temperature as in the app (the 4B gave identical output across two runs). gpt-oss-120b wasn't run: OmniRoute's key is in the Keychain, which a headless session can't unlock.

| | Clean corrections resolved | Lookalikes kept | Prompt corrections resolved |
|---|---|---|---|
| 4B, no rule | 3/5 (missed "actually sixty", kept "scratch that" literally) | 5/5 | — |
| 4B, rule (shipped wording) | **5/5** | 4/5 (dropped an answering "No,") | **3/3** |
| qwen3:8b (Ollama), rule | **5/5** | **5/5** | **3/3** |

- The Prompt samples have to be punctuated the way the engines write pauses ("blue, no, green"). Unpunctuated, "blue no green" reads as "blue, not green", and every model (with or without the rule) wrote the opposite of what was meant.
- A wording with a list of correction words and a lowercase example ("meet at two, no, make it three" → "meet at three") made the 4B write whole answers in lowercase without punctuation. The shipped examples are written as full sentences.
- The 4B's output shifts with any prompt change: one lookalike question ("is it two or three people coming, I'm not sure") came back as a statement under the shipped wording and kept its "?" under the first one. qwen3:8b kept the meaning every time.
- Latency unchanged: Clean 0.4–0.7 s, Prompt 0.8–1.1 s on the 4B.

## Super on the on-device 4B (`lsbench rewrite`, `tools/lsbench/samples/super.jsonl`), 2026-10-12

P3.5 B1. Twenty samples through `SuperPrompt`: 10 edits of a selection (shorten, more polite, translate, bulleted list, fix grammar, more casual, a self-corrected change, add a sentence, a question about the text, commit message) and 10 writes at the cursor (7 replies with the field as context, 3 with an empty field). Qwen3-4B-Instruct-2507 4-bit on the M5: load 0.48 s, every answer 0.36–0.89 s (6–23 output tokens, ~47 tok/s), peak 2.9 GB, no answer rejected by the length check.

- **18/20 usable as is.** Edits kept facts and formatting (the list came out as five "-" bullets, "Tuesday, no, actually Thursday" → Thursday, the added sentence left the original untouched). Replies used the field: "Congrats on the new job, Priya!", "Yes, let's pair on the flaky test this afternoon. What time works for you?", a Spanish reply to a Spanish message, a one-line thread summary naming Sara and the lint rule.
- Weak: "what does this mean" lightly reworded the selection ("regressed" → "increased") instead of returning it unchanged; the out-of-office message was only "I'm back on Monday, the 20th." "Fix the grammar" dropped the final "too".
- Superwhisper's warning that small local models do Super badly doesn't hold for these short tasks, so Settings carries no warning. Longer edits (a page of text) aren't measured yet.

Early detection (the peek Super runs while recording): `say` clips of four dictations, cut at 1.0, 1.7 and 2.5 s and transcribed by Apple Speech (`lsbench --engine apple`, ~70 ms each). "Super, make this shorter…" → "Super." at 1.0 s, "Super, make this shorter." at 1.7 s; "Super. Reply saying…" and "Um, super, fix the grammar…" the same way. "Super excited to join…" → "Super excited." at 1.0 s, so `SuperTrigger.earlyVerdict` never shows Super for it. Synthetic voice only; the user's voice and a slow "super… excited" are still to be tried live.
