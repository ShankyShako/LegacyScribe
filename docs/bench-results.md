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

## Notes data safety with speaker labels (`tools/notes-crashtest.py --voiceprints`), 2026-10-16

The same checks after speaker labels changed the chunk pipeline (Silero gate → diarizer → one Cohere call per turn, `speakers.json` saved before each commit). Feed: the first 10 min of the Hack-A-Roo Q&A recording (several speakers, the user among them), with the user's voiceprint copied into every scratch root.

| Check | Result |
|---|---|
| Reference | 24 chunks, 1,505 words |
| kill -9 while recording, then relaunch | PASS: 10 chunks |
| kill -9 while transcribing | PASS: 24 chunks |
| kill -9 while writing notes | PASS: 24 chunks |
| Chunk 4 fails once, chunk 9 twice | PASS: 9 a gap with its audio in `failed/`, 4 recovered after a reload |
| Peak footprint while transcribing | **2.82 GB** (by third 2.61 / 2.77 / 2.82), up from 2.13 GB without labels; notes 0.84 GB |

The diarizer adds about 0.7 GB while transcribing. The thirds still rise slightly over 10 minutes; the 2-hour `--long` run hasn't been repeated with labels on, so flat memory over a long session is unproven.

**Overnight run, 2026-10-17** (`tools/overnight.sh`, step `notes-long`; the build now also stores each line's `seconds` for Notes trimming). Same 10-min Q&A feed, plus a 2-hour and a 60-min feed looped from it:

| Check | Result |
|---|---|
| Reference (10 min) | 24 chunks, 1,505 words |
| kill -9 while recording / transcribing / writing notes | PASS: 10 / 24 / 24 chunks |
| kill -9 after a notes part was saved (60-min feed) | PASS: 144 chunks, 9,005 words |
| Chunk 4 fails once, chunk 9 twice | PASS: 9 a gap in `failed/`, 4 recovered after a reload, up to 8 chunks queued |
| Peak footprint while transcribing, 10 min vs 2 h (288 chunks) | **3.45 GB vs 3.42 GB** (thirds 2.64 / 2.92 / 3.45 vs 3.42 / 2.80 / 2.52): flat |
| Writing notes: 10 min vs 2 h | 0.81 GB vs 4.08 GB |

Flat memory over a 2-hour labelled session is now shown: the long run's peak is 99% of the short one's and its thirds fall. The 10-min peak is 0.6 GB above the 2026-10-16 run on the same feed (2.82 GB); the long run's falling thirds point to Metal freeing lazily rather than a leak, but it hasn't been chased.

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

## MLX memory leak per model load (`lsbench --reload-loop`), 2026-10-14

The Release app sat at 416 MB at rest after ~26 dictations on Cohere 4-bit (loaded per dictation). `heap -s` showed 283k `mlx::core::array::ArrayDesc` plus `Quantize`, `RandomBits`, `Split` and Metal buffers left over: ~7–12 MB per load, never freed.

- mlx-swift 0.32.3 `MLXArray._updateInternal` assigns with `mlx_array_set` (C++ copy assignment), which skips `array::~array()`'s sibling-cycle breaking. `Module.update(parameters:)` uses it to put loaded weights over a fresh `QuantizedLinear`'s random init (unevaluated `Quantize` siblings), so the init graph is orphaned on every load. Affects Cohere and the on-device Qwen rewrite.
- Model construction also draws ~900 keys from `MLXRandom.globalState` lazily; unevaluated, the key chain grows.

| `lsbench --engine cohere:… --reload-loop N` | `ArrayDesc` after 0 reloads | after 10 |
|---|---|---|
| mlx-swift 0.32.3 | 7,785 | 85,445 |
| fork `056ea0d` + `eval(MLXRandom.globalState)` | 19 | 19 |
| fork `37407d1` (2026-10-15: also safe for `a._updateInternal(a)`) | 19 | 19 |

Footprint after the wait: 49 → 120 MB unpatched, 32 → 34 MB patched. Transcription speed unchanged (127 ms on a 3.9 s clip).

Rerun 2026-10-15 on `37407d1` (Debug lsbench): footprint after the wait 35 → 38 MB; the 1,594 MB printed right after the loop is Metal memory not yet handed back, gone 10 s later. Cohere 4-bit corpus WER 4.58% on the `say` fixtures. The on-device 4B still answers the self-correction samples in 0.4–1.1 s at ~41 tok/s.

## Parakeet v3 while loaded (`lsbench --engine parakeet:v3 --reload`), 2026-10-15

P3.6 D3: is it worth unloading the default engine at rest? No. Loaded, the process holds ~52 MB (Core ML keeps most of the model outside it); unloading and waiting 5 s leaves it at 52 MB, and reload + warm-up takes 0.17 s. Load 0.3 s, corpus WER 6.87% on the `say` fixtures, 36–177 ms per clip. WhisperKit not measured: no WhisperKit model is downloaded on this Mac.


## Fillers in transcripts (speech coach risk check), 2026-10-15

P3.6 D6: do the engines write the user's ums? Ten of the user's dictations (20–83 s, 9 min in all, picked across History; three chosen because Cohere wrote an "um" in them) transcribed by each engine (`lsbench --runs 1`). Files, scripts and a listening page for the by-ear count: `<data root>/bench/fillers/` (`listen.html`).

| Engine | Fillers written | Words |
|---|---|---|
| Parakeet v2 | 8 | 669 |
| Parakeet v3 | 9 | 681 |
| Apple Speech | 8 | 672 |
| Cohere 4-bit | 3 | 648 |

- The three that write fillers agree clip by clip (all eight of Apple's match Parakeet v3's nine). Cohere drops two in three. Over the whole History the pattern holds: Cohere wrote 6 fillers in 181 min of the user's speech.
- So the coach can't count from History's text (Cohere). It has to transcribe the audio again with Parakeet v3 (loaded anyway, ~100× real time), which limits filler counts to entries that still have audio (30 days).
- By ear (the user, `listen.html`, 2026-10-15): 8 hesitation fillers in the 10 clips (01–04, 07–10 one each; 05, 06 none), plus an "uh, oh" in 03 said as a question while checking the microphone. Parakeet v3 matches clip for clip: it writes all 8 and the "uh" of 03 (its 9), missing none and inventing none. Parakeet v2 misses 08's; Apple Speech misses 04's (music in the background); Cohere writes 3. So the coach's filler counts on Parakeet v3 can be taken at face value on the user's voice; an interjection "uh" counts as a filler.
- Detecting filled pauses from sound alone, as a sustained flat vowel (`fillers_detect.py`, after Goto et al. 1999), didn't work: at best it found 3 of 8 written fillers with 23+ false alarms, many of them drawn-out words ("the…", "to…"). Parakeet TDT's word ends run up to the next word, so the gaps between words can't locate a hesitation either. New `lsbench words <audio or folder>` prints TDT word timings as JSON lines for this kind of analysis.

The coach's analysis (`SpeechCoach` in HexCore, `lsbench coach <folder>`) on the same 10 clips: 422 s of audio in 2.0 s with Parakeet v3 on the M5. 1.3 fillers and 0.9 self-corrections per 100 words; 98 words a minute counting pauses, 177 between them; median pause 0.66 s after a sentence and 0.68 s inside one, longest 14.2 s; 22% of fillers in the first 2 s. With pauses counted, pace reads as "slow" and one 10 s stop to think lifts the mean pause to 1.1 s, so the coach reports pace without pauses (articulation rate) and median pauses. Pauses come from loudness (`PauseFinder`, silences ≥ 0.3 s between the first and last word), not from TDT word gaps.


## Pitch range for the filler-free minute (2026-10-15)

`PitchTracker` (autocorrelation on 40 ms frames at 8 kHz, first peak within 90% of the best, parabolic lag interpolation; 10th–90th percentile spread in semitones) on the 10 History clips of "Fillers in transcripts", via `lsbench coach`:

| | 01 | 02 | 03 | 04 | 05 | 06 | 07 | 08 | 09 | 10 |
|---|---|---|---|---|---|---|---|---|---|---|
| Semitones | 6.2 | 5.0 | 5.2 | 7.7 | 5.3 | 3.9 | 5.6 | 3.2 | 5.5 | 6.7 |

Before frames more than ~11 semitones from the clip's median were dropped, clip 04 (30 words) read 20.6: octave errors. A synthetic 120→180 Hz glide (7.0 semitones end to end) reads 5.0–6.2 as expected for a 10–90% spread; a steady tone reads under 0.5. These are dictations, which are flatter than talking to a person; the coach shows pitch only for the filler-free minute. The same run found crutch words in 2 clips ("just") and hedges in 2 ("I think" 5× in clip 10), no run-ons.


## Pauses: loudness only, after two vetoes failed by ear (2026-10-15)

The user played the coach's "you paused instead" snippets and heard themselves talking in some, mouth away from the microphone: `PauseFinder`'s loudness threshold took quiet speech for silence. Two checks now veto a loudness silence: Parakeet wrote a word starting more than 0.25 s into it and more than 0.5 s before its end (TDT starts words up to ~0.5 s early, so a 0.3 s margin dropped real pauses before "wanna", "or", "The"), or Silero VAD (FluidAudio, 256 ms frames, probability ≥ 0.7) hears speech come back inside it, or throughout. Silero's first frame or two after speech still read 0.9–1.0 (one 17.3 s silence started 1.00, 1.00, then ~0.01), so voiced frames only at a silence's start don't count; at 0.5 a soft onset ("f" of "folder") at a silence's end vetoed it, hence 0.7, FluidAudio's own exit threshold.

`lsbench coach`, Parakeet v3, M5:

| | Silences ≥ 0.3 s | after word check | after VAD too | Pace while speaking | Median pause (sentence / thought) |
|---|---|---|---|---|---|
| 10 filler clips (422 s), loudness only (before) | 164 (184 s) | | | 177 wpm | 0.66 / 0.68 s |
| 10 filler clips, both checks | | 159 (173 s) | 156 (168 s) | 165 wpm | 0.61 / 0.64 s |
| 315 History recordings (12,288 s, 75 s to analyse) | 4,275 (4,899 s) | 4,238 (4,800 s) | 4,119 (4,667 s) | 176 wpm | 0.82 / 0.74 s |

The vetoed stretches on the History recordings that are clearly speech: whole runs at −16 to −18 dB with Silero at 1.00 for several frames and Parakeet words deep inside (one recording where background sound lifted the loudness threshold), and a 3.4 s "silence" at −47 dB with a 0.95 frame in its middle.

**By-ear check (2026-10-15), and the checks redone.** The user labelled 20 randomly picked vetoed stretches (12 Silero, 8 word; `<data root>/bench/pauses/listen.html`): 15 silence, 4 talking, 1 someone else. By check: Silero 10 of 12 silence, words 5 of 8 silence (2 talking, 1 other). The waveforms (100 ms RMS) of all four "talking" ones are a flat noise floor across the gap (−31 dB in the noisier recordings, −49 dB in the quiet ones), so the talking heard was most likely the half second played either side; the one with something in it (item 8, a 0.2 s bump 6 dB over a −49 dB floor) was a breath that Parakeet wrote as "should they" and Silero scored 1.00. What went wrong:

- Silero lights the frame before speech returns as well as the two after it stops ([1.00 0.13 0.99], [0.43 0.90]), so a 0.6 s gap read as voiced throughout ([1.00 0.97]).
- Parakeet places words in noise: four of the five silent word vetoes had a word starting 0.52–0.56 s before speech resumed (TDT starting early), one a word in the middle of a flat floor.

Second try: Parakeet's words don't veto, and Silero vetoes only when it hears speech once up to 2 leading and 1 trailing voiced frames are set aside (no "voiced throughout" rule). It vetoed 25 of 4,316 History silences (159 of 164 left on the filler clips). The user labelled all 25 (`listen2.html`): 22 silence, 3 talking. The five loudest (−14 to −18 dB, Silero 1.00 for up to 6 frames, Parakeet "sure that the", "on how") were background music, the bar lifted by it; one of those had the user's "um". The three talking ones scored like the silent ones (talking [0.62 0.48 0.79 1.00 0.10 0.09], silent [0.60 0.28 0.86 0.99 0.70 0.10]), so no threshold separates them. A gate on a level rise inside the gap was also tried (veto only with a run 6 dB over the gap's own median): 3 vetoes of 4,316.

**Decision: pauses are loudness only**, no VAD and no word veto (`CoachClip` version 4; the analysis is also ~15% faster without the VAD pass). Across both checks loudness was right on 37 of the 45 stretches (82%) the vetoes had taken away from it, and the talking the user first heard in "you paused instead" snippets was most likely the 4 s snippet window running past the pause into speech (the clean-sentence example has replaced those snippets). 10 filler clips: 164 pauses (184 s), 177 wpm while speaking, medians 0.66 / 0.68 s. 321 History recordings: 4,316 (4,935 s), 182 wpm, 0.82 / 0.76 s; 102 clean sentences in 83 recordings.

The good example is now a clean sentence (8–25 words, closed by . ? !, no filler, crutch word, hedge or correction, no pause over 1 s, its quietest fifth of words ≥ 0.3× and its middle word ≥ 0.6× the recording's typical word level): 105 in 86 of the 315 recordings, up to 2 per recording.

## Voiceprint check: CAM++ on the user's voice (2026-10-15)

Can FluidAudio's CAM++ speaker embedding (192-d, `campplus-coreml`, beta conversion, 17.5 ms per stretch on the M5) tell the user from other people, before Notes counts only the user's speech (plan P3.6 D6)? `lsbench voice`: the voiceprint is the mean embedding of the 68 read-aloud recordings (their own scores against it 0.79–0.91, median 0.91); up to 4 stretches per length per file of contiguous speech (Silero VAD, the notes settings) from 327 History recordings (the user, held out; built-in mic and AirPods, a few with background music) and from other voices: Mini LibriSpeech dev-clean-2 (26 speakers with ≥ 1 usable file of the 40, ≤ 10 files each, audiobook recordings) and 22 macOS `say` voices (2 lines each). Cosine score against the voiceprint:

| Stretch | User median (5th pct) | LibriSpeech median (95th pct) | EER, all others | Others let in at 95% / 90% of the user accepted |
|---|---|---|---|---|
| 1 s | 0.66 (0.45) | 0.39 (0.60) | 12.6% at 0.54 | 33% / 17% |
| 2 s | 0.74 (0.59) | 0.43 (0.64) | 7.3% at 0.62 | 11% / 5.7% |
| 5 s | 0.82 (0.71) | 0.45 (0.73) | 5.2% at 0.72 | 5.6% / 2.6% |

`say` voices are easier than people (5 s EER 0.5%). One LibriSpeech speaker (2428) sits close to the user at every length (5 s median 0.76, max 0.80, against the user's 0.82), and four more reach 0.74 at 5 s: the errors are a few voices that sound like the user, not noise spread over everyone. The user's lowest stretches (negative at 1 s) come from recordings with music or someone else and haven't been listened to.

Reading: under 2 s the voiceprint can't decide a turn on its own; at 5 s it is right ~95% of the time against people recorded elsewhere. Same-room voices through the same microphone haven't been tested and will score closer (shared room and channel), so this is a best case. Not tried: scoring a whole turn rather than fixed stretches, enrolling from History (dictation conditions) instead of read-aloud, a stretch-length-dependent threshold, FluidAudio's WeSpeaker embedder from the diarizer.

**Follow-up the same evening: WeSpeaker, History enrolment, whole turns, a video in the room.** `lsbench voice` gained `--embedder wespeaker` (the diarizer's WeSpeaker v2, 256-d, 10 s window, `Models/fluidaudio/speaker-diarization-coreml`), `--enrol-from-same N` (voiceprint from N History recordings spread over them, held out of the test) and whole VAD turns (first 10 s). EER against all others (LibriSpeech + `say`):

| Embedder, enrolled from | 1 s | 2 s | 5 s | turn 2–5 s | turn 5 s+ |
|---|---|---|---|---|---|
| CAM++, 68 read-aloud lines | 12.9% | 7.3% | 5.3% | 4.3% | 3.7% |
| CAM++, 40 History dictations | 11.0% | 4.7% | 3.5% | 1.6% | 3.2% |
| WeSpeaker, 68 read-aloud lines | 5.1% | 1.5% | 1.0% | 1.4% | 1.0% |
| WeSpeaker, 40 History dictations | 5.0% | 1.2% | 0.8% | 1.4% | 0.6% |

WeSpeaker with the History voiceprint lets in 4.8% of others at 1 s and none at 2 s or longer when 95% of the user's stretches are accepted (CAM++: 30% / 4.5% / 2.2%); 18–20 ms per stretch against CAM++'s 16. LibriSpeech speaker 2428, CAM++'s near-double of the user, scores 0.34–0.42 on WeSpeaker against the user's 0.70–0.85. Turns of 1–2 s are left out: the other sets have only 9 (audiobook speech is continuous). CAM++ takes at most 60 s of audio (its fbank model stops at 6,000 frames), so long enrolment recordings are averaged over 50 s pieces.

Same room: the user dictated two messages with a video (another person talking) playing from the Mac's speakers (1792121415, 21.5 s; 1792121581, 15.3 s). Silero hears speech throughout both, so turns can't split them; `--timeline` scores 2 s windows every 0.5 s. Cohere wrote only the user's words in both; Parakeet transcribed the video in the second. WeSpeaker, History voiceprint: windows over the user's words (with the video underneath) 0.45–0.73; windows with only the video (Parakeet's video words, absent from Cohere's text: 9.0–10.0 s and 15.0–18.0 s of the first, 7.5–12.0 s of the second) −0.02–0.32. A threshold near 0.4 splits every window whose content is known; the first 3.5 s of the second dictation sit at 0.26–0.43, where Parakeet heard only the video and the user's opening words must lie, so that stretch is likely both at once. CAM++ on the same windows: user 0.55–0.75, video 0.29–0.54, overlapping.

Reading: WeSpeaker, enrolled from History dictations, is the voiceprint to build on. Two dictations are a small same-room test; a longer recording with a conversation or a podcast would firm it up.

**A real meeting, diarized (2026-10-16).** `lsbench voice --diarize <file>` runs FluidAudio's diarizer (pyannote segmentation + WeSpeaker, default clustering) over a whole recording. It scores each speaker's mean segment embedding, and each turn's, against the History voiceprint, then transcribes each turn with Parakeet v3. The diarizer's segment embeddings aren't unit length, so they are normalized first; unnormalized, the scores went above 1. The test recording was the second half of the Hack-A-Roo Q&A on Zoom: 18 min, 4–5 remote voices. The user was muted on Zoom and talked over the others on purpose. Diarization took 4 s.

| Speaker | time | voiceprint (speaker mean) | who, from the transcript |
|---|---|---|---|
| S2 | 416 s | 0.07 | the professor |
| S3 | 222 s | 0.06 | a nurse practitioner |
| S1 | 146 s | 0.24 | an organizer (rundown, the NRT mentor) |
| S4 | 98 s | 0.45 | the same organizer's rundown from 0:48, with the user talking over it ("This is speaker one by the way" sits inside one of its turns) |
| S5 | 18 s | 0.61 | short asides, most likely the user ("Right.", "Um", "Oh once they join a project.") |
| S6 | 3 s | 0.04 | one "Oh." |

- The voiceprint ranks the clusters correctly. The likely-user cluster scores highest, the mixed cluster second, and every remote voice stays at 0.24 or below.
- Overlap is the weak point. Where the user talked over someone, the diarizer gave the stretch to one speaker: one organizer was split into S1 and S4, and Parakeet wrote both voices into one line. Most of the user's talking ended up inside other speakers' turns, not in S5.
- Checked with the user afterwards: they talked most from 0:48 to 2:10, over the rundown, and also at 1:10, 1:43, 14:55 and in a closing "thank you". S5 and the S4 rundown match that.

The user's voice can still be found under someone else's with `--timeline`, which scores 1 s and 2 s windows every 0.5 s against the voiceprint (cutoff 0.4, from the video test):

| Stretch | who | 2 s windows over 0.4 | 1 s windows over 0.4 |
|---|---|---|---|
| 0:48–2:10 | the user talking over the rundown | 39% | 22% |
| 14:50–15:12 | the user's "phone in your front pocket" aside | 34% | 23% |
| 0:00–0:48, 2:10–2:50 | the organiser alone | 2% | 1% |
| 2:50–14:50, 15:12–end | the others | 0% (2 windows: 4:01, 8:03) | 0% |

- **Windows find the user where the diarizer couldn't.** The 2 s windows over 0.4 run almost continuously from 0:47 to 1:59 and again from 14:55 to 15:12. Elsewhere, 14 min of other voices gave only two false hits. The user doesn't talk the whole time in either stretch, so 39% is a floor on the true detection rate, not a measure of it.
- **The closing "thank you everyone" was missed** (max 0.30): it was short and said at the same moment as the professor's.
- **Reading:** to count only the user's speech in Notes (the coach), take speech from 2 s windows over 0.4, not the cluster labels. For "who said what", diarize, label the cluster with the highest score over 0.4 as the user, and mark other speakers' turns that contain such windows as overlapping with the user.

## Cohere's trailing "thank you" (2026-10-15)

The user noticed dictations ending in "Thank you." they hadn't said. In History, 16 of 329 dictations end that way, all in the raw transcript (Cohere 4-bit), so not the rewrite. Parakeet v3 hears "thank you" in 2 of them (1792097084, 1792103919: said). The other 14: five recordings of 0.3–2.9 s with no speech at all (Silero finds none) that Cohere writes as "Thank you.", and nine dictations of 25.7–33 s. mlx-audio's splitter cuts at the quietest point within ±5 s of each 25 s mark, which for a 25–30 s dictation is often the silence after the last word; the leftover sliver (padded to 1 s) comes back as "Thank you.".

Now `CohereChunks` (HexCore): up to 30 s is one pass; longer audio is cut into ceil(length / 24 s) even pieces at the quietest 0.1 s within ±3 s of each mark (9–30 s each), transcribed one by one. Dictation's audio also goes through the notes speech gate first (Silero VAD, stretches joined with 0.2 s gaps; under 0.5 s of speech → empty, nothing pasted).

| The 16 "Thank you." endings | Before | New cuts | New cuts + gate |
|---|---|---|---|
| Not said (14) | 14 kept | 9 gone (the long ones) | 14 gone |
| Said (2) | kept | kept | kept |

Regression check on 25 random History dictations over 30 s, WER against Parakeet v3's transcript (not a human reference): old splitter 8.83%, new cuts 7.42% (7 better, among them 25.7% → 9.2% and 18.5% → 3.1%; 3 slightly worse; 15 the same), new cuts + gate 7.63%. The gate's worst file (3.1% → 10.8%) lost "this is not a real" said twice, which Parakeet keeps and Cohere wrote once: a restart, not content. The voice fixtures are all under 30 s, so they are one pass either way and unchanged. The same evening the user got a false "Thank you." on a 27.2 s dictation (1792121818: "…we can look into them. Thank you."; Parakeet's last word "them" at 26.0 s, then 0.8 s at −50 dB): the running Debug app was built at 20:59, before this fix. `lsbench` reproduces it with mlx-audio's splitter (`--cohere-chunk 25`) and not with the new cuts, whole or gated. Not yet checked in a build that has the fix. After the rebuild (22:49) one more came: an 11.2 s recording that is near-silent throughout (loudest 100 ms −45 dBFS, Parakeet hears nothing). Silero called 1.1 s of it speech, past the gate's 0.5 s, and Cohere wrote "Thank you.". Over the 346 History recordings with audio, the loudest 100 ms of every real dictation reaches −27 dBFS or more (quietest: "Yep." −26.6, "Oh." −25.6), so dictation audio that never reaches −40 dBFS is now treated as silence and pastes nothing (`NotesSpeech.dictationFloorDecibels`; not applied to Notes, where a voice across the table can be that quiet). The three short silent "Thank you." recordings peak at −18 to −25 dBFS (a key click) and are caught by the VAD, not the floor.

## Restarts in "clean" sentences (2026-10-15)

The user heard repeats inside "Said cleanly" examples. Only one word said twice in a row ("the the") counted as a repeat. Of 102 clean sentences on History, 17 repeated a phrase; 11 were restarts the coach missed ("you can you can", "if you if you", "I w I was", "their m their mind", "if you want to do if you want to opt out", "I'm planning to use it to I'm planning to use it"). `CoachText.restarts` now counts a phrase of up to 5 words said again at once, after a cut-off word (the start of the repeated word or the next one), or for 2+ words after one other word, unless that word ends with a comma (a list: "how many people are online, how many people are viewing"). Counted as `repeated` corrections, so they also feed the corrections rate (1.4 → 2.1 per 100 words on History). Clean sentences: 102 → 93; none restarts. Still let through: parallel phrasing (4, fine) and swaps that aren't repeats ("does not is not", "the or the next"). `CoachClip` version 5. The user found the "Said cleanly" examples clean in the running app, but that build (20:59) predates this change, so it was version 4.

## S1-mini against the on-device 4B for Clean (2026-10-15)

[S1-mini](https://huggingface.co/superwhisper/s1-mini) is Superwhisper's Qwen3-0.6B fine-tune for transcript cleanup (fixed system prompt plus a control line, English, greedy). Converted with `mlx_lm.convert` (4-bit, 4.5 bits/weight, 331 MB; BF16 1.1 GB) and run through `lsbench rewrite` (`"mode": "s1"`, semi-formal / prose / general) on 40 held-out Clean dictations from History (`tools/finetune/split.py`, stratified by length; the reference is the gpt-oss-120b text that was pasted). Scored by `tools/finetune/score.py`. M5, Release lsbench.

| | WER vs gpt-oss | words changed vs heard | median s | peak MB (lsbench) |
|---|---|---|---|---|
| Heard text, untouched | 44.9 | 0 | – | – |
| gpt-oss-120b (what was pasted) | 0 | 34.1 | – | – |
| Qwen3-4B-Instruct-2507 4-bit, app's Clean prompt | 31.4 | 24.6 | 1.14 | 3176 |
| S1-mini 4-bit | 44.1 | 1.9 | 0.24 (~210 tok/s) | 993 |
| S1-mini BF16 | 44.1 | – | 0.59 (~83 tok/s) | 1831 |

WER against gpt-oss is not accuracy: gpt-oss paraphrases (once it changed the meaning: "I just want to make sure this isn't something new to me" → "…we didn't overlook this"), so the comparison needs a reader's judgment, not this number.

- **On Cohere transcripts S1-mini does almost nothing.** It was trained on raw lowercase, unpunctuated ASR; Cohere already punctuates and drops two fillers in three (4 of 332 heard texts in History contain um/uh). Its few edits were commas, "gonna" → "going to", hyphens, and once a dropped sentence (83 words in, "scroll the page all the way to … Why force the" gone).
- **On Parakeet v3 transcripts (the 10 filler clips) it removes fillers and writes numbers as digits** ("fifty percent" → "50%"), keeping the speaker's phrasing where the 4B smooths it. But in 10 clips it twice changed content: "super base" became "Superwhisper" (its own brand, leaked from training), and a clause run after "I mean, you can't I I think" was dropped as if it were a self-correction (two sentences lost). It also put paragraph breaks mid-dictation twice.
- **Verdict:** ~5× faster and a third of the memory, but not a better Clean model than the 4B; its one job overlaps what Cohere already does. Useful at most as an 8 GB Mac's filler remover on Parakeet output, and the content drops argue against even that without more testing. A Qwen3-0.6B fine-tuned on the user's own dictations (input like ours, already punctuated) is the better candidate.

## Two Qwen3-0.6B fine-tunes, Heavy and Light, judged blind (2026-10-16)

The user prefers heavy rewrites and asked for two small models side by side. Qwen3-0.6B (BF16) LoRA-trained with `mlx_lm.lora` 0.32.2 on the 262 training dictations of the pool (30 held for validation, `tools/finetune/build_dataset.py`; short system prompt "Rewrite this dictation as clean written text."; all layers, rank 8, lr 1e-4, batch 4, prompt masked). **Heavy** learns the gpt-oss-120b text that was pasted; **Light** learns the on-device 4B's rewrite of the same transcripts. Training takes about a minute per 200 steps on the M5. Validation loss bottoms out at step 125 (~2 epochs: Heavy 0.43, Light 0.38) and rises after, so that checkpoint was fused and quantized to 4-bit (331 MB each).

Small greedy models loop sometimes ("Super. Super. Super." for 4,096 tokens; 3 of 80 answers). `lsbench rewrite` now caps "s1"/"chat" answers at 2.5 × the heard words + 64 tokens and retries a capped answer once with repetition penalty 1.1, as on-device notes do; an answer still cut off falls back to the heard text, as the app's length check would (1 for Heavy, 1 for Light).

A blind judge (a separate Opus agent reading only shuffled letters, `tools/finetune/judge_packet.py`, unblinded by `unblind.py`) scored all six systems on the 40 held-out dictations, 1–5 per criterion, and ranked them:

| System | faithful | clean | professional | structure | mean rank (1 best) | rank, 80+ words | wins | serious faults |
|---|---|---|---|---|---|---|---|---|
| gpt-oss-120b (pasted) | 4.60 | 4.83 | 4.83 | 4.55 | 1.88 | 1.11 | 25 | 5 |
| Qwen3-4B, Clean prompt | 4.60 | 4.42 | 4.38 | 4.50 | 2.33 | 2.00 | 7 | 7 |
| Heavy 0.6B | 4.10 | 3.75 | 3.77 | 4.45 | 3.80 | 4.22 | 3 | 12 |
| S1-mini | 4.95 | 3.00 | 3.23 | 4.47 | 4.08 | 4.22 | 3 | 14 (all "left uncleaned") |
| Light 0.6B | 4.15 | 3.40 | 3.48 | 4.40 | 4.22 | 4.56 | 1 | 13 |
| Qwen3-0.6B, untrained, Clean prompt | 4.35 | 2.88 | 3.10 | 4.38 | 4.70 | 4.89 | 1 | 19 |

Speed and memory (lsbench peak, including the tool): 0.6B models 0.19–0.24 s median, ~1.0 GB; 4B 1.14 s, 3.2 GB.

- **Training works but isn't enough yet.** Heavy moved the 0.6B from last (4.70) to third (3.80), ahead of S1-mini and Light, but its 12 faults are the dangerous kind: invented phrases ("the implications of the text", "in a future scenario"), dropped points on long dictations, a request softened to a permission. Light was garbled on one long dictation (repeated sentences, most points gone). 262 examples teach the style, not the judgment. Not shippable; the 4B stays the on-device default.
- **The heavier teacher is the better teacher**: Heavy beat Light on every criterion but faithfulness (a tie), matching the user's preference.
- **Every system writes long dictations as one paragraph**: all 9 dictations of 80+ words, gpt-oss included (S1-mini split 2). The app's Clean instructions say nothing about paragraphs. Adding "Break a dictation of more than a few sentences into paragraphs where the topic shifts, separated by a blank line. Keep a short dictation as one paragraph." (via lsbench's new `"append"` sample field) made the 4B split 6 of 9 into 2–4 paragraphs; its answers were 18% shorter than the heard text, from fillers and repeats, with no point dropped (read by eye). See "Paragraphs in Clean" below.
- Next for a shippable small model: more and broader data (Notes chunks labelled on this Mac by qwen3.6:27b, synthetic dictations), training on the paragraph-aware teacher, and the same blind judging.

## Paragraphs in Clean (2026-10-16)

The rule from the fine-tune study, tried on gpt-oss-120b (the user's primary, through OmniRoute) and the 4B over the 40 held-out Clean dictations, inside the Clean task:

| Wording | gpt-oss: long (80+ words) split | gpt-oss: shorter split | 4B: long split | 4B: shorter split |
|---|---|---|---|---|
| "Break a dictation of more than a few sentences into paragraphs where the topic shifts, separated by a blank line. Keep a short dictation as one paragraph." | 3 / 9 (285 words → 4) | 0 / 31 | 6 / 9 | 2 / 31 |
| "Split a dictation that moves between topics or runs longer than about five sentences into paragraphs, one per topic…; don't run several topics together in one block…" | 4 / 9 | 1 / 31 (71 words) | – | – |

- Read by eye, the 4B's nine long answers keep every point; they are 18% shorter than the heard text from fillers and repeats (gpt-oss's are ~30% shorter). Its two short splits fall at real topic changes ("…better test than the tapping test?" / the dashboard window size).
- gpt-oss splits only when the dictation is long and clearly changes subject; 80–130-word answers stay one paragraph, which reads fine. A 164-word dictation stayed one block under both wordings.
- The first wording went into the app's Clean task.

## Prompt mode as a numbered reply (2026-10-16)

The sectioned Prompt shape (synopsis, named sections, bullets, open questions) against a numbered reply, on 8 long real dictations (558–1,733 characters) sent to gpt-oss-120b with the app's full system prompt (code talk included), then the tightened version also on 8 short ones and on the 4B. Report with every answer: `<data root>/prompt-trial/report.md`.

| | numbered (of 8 long) | median s | short ones kept plain |
|---|---|---|---|
| Sectioned (old) on gpt-oss | – | 8–12 s in 5 of 8 (second pass) | – |
| Numbered, first draft, on gpt-oss | 6 | 3.9 (mean) | – |
| Numbered, "always numbered" + "a phrase you can't make sense of stays as said", gpt-oss | **8** | 1.5 | 8 / 8 |
| Same, plus a two-line format example | 7 | 1.6 | 8 / 8 |
| Same as the shipped one, on the 4B | 0 | 2–5 | 6 / 8 (2 turned into "Can we…?" questions) |
| With the format example, on the 4B | 4 | | answered the questions instead of rewriting them ("Place the user… with a slight tilt") |

- The sectioned shape repeated itself, turned asked questions into statements and dropped side items; the numbered one keeps the spoken order, every point and every question.
- The trial flagged one invented sentence in the numbered reply ("I'm not saying we should buy or automate anything"); the speaker did say it ("I'm not saying we bought it or automated"). Its real stretches were guesses at unclear phrases ("make it how" → "a more detailed offering"), which the new "stays as said" clause targets. The shipped version still guessed it once, more mildly ("build it out"), and dropped one description item (pigu.lt looks like Amazon); the run with the format example kept both as said ("make it …").
- The 4B is not a Prompt-mode model: it ignores the numbering, pads and turns statements into questions. Prompt mode wants a cloud model.

## Apple Speech's raw text as the rewrite's input (2026-10-16)

The 332 pool and eval dictations (199 min of History recordings) transcribed again by Apple Speech (`lsbench --engine apple`): 0.4 s load, ~120× real time, 7.6% of words differ from the Cohere text the user dictated with. Most of the difference is Apple writing what was said: 147 um/uh against Cohere's 6, repeats kept ("if, if", "I, I"), restarts ("keep continue"), and sentences cut by stray periods ("missing a lot of details. From the actual apps usage."). It ended 2 dictations with "Thank you." where Cohere ended 15, and wrote nothing for 6.

Raw mode on Apple Speech would paste all of that, so it needs a rewrite. Two questions were tested: does a rewrite from Apple's text match one from Cohere's, and does training the 0.6B on both texts (520 examples: each pool dictation twice, same pasted target; `build_dataset.py --also-inputs`, best checkpoint step 225) make a better small model ("v2")? Same blind judge set-up as above, now 7 systems; the packet shows both heard texts (`judge_packet.py --also-heard`) without saying which system started from which.

| System | faithful | clean | professional | structure | mean rank (1 best) | rank, 80+ words | wins | serious faults |
|---|---|---|---|---|---|---|---|---|
| gpt-oss-120b on Cohere (pasted) | 4.62 | 4.92 | 4.85 | 4.75 | 2.75 | 2.11 | 9 | 3 |
| gpt-oss-120b on Apple | 4.33 | 4.72 | 4.62 | 4.90 | 3.10 | 2.33 | 13 | 6 |
| 4B on Cohere | 4.60 | 4.40 | 4.30 | 4.72 | 3.38 | 3.00 | 4 | 3 |
| 4B on Apple | 4.30 | 4.35 | 4.28 | 4.92 | 4.10 | 2.89 | 7 | 8 |
| Heavy 0.6B on Cohere | 3.95 | 3.90 | 3.73 | 4.65 | 4.55 | 5.56 | 2 | 15 |
| v2 0.6B on Cohere | 3.50 | 3.95 | 3.83 | 4.65 | 4.95 | 5.78 | 3 | 17 |
| v2 0.6B on Apple | 3.12 | 3.75 | 3.60 | 4.53 | 5.17 | 6.33 | 2 | 22 |

- **Every system is less faithful from Apple's text**: gpt-oss 3 → 6 faults, the 4B 3 → 8. Apple's misheard words and stray periods get rewritten into confident wrong sentences (gpt-oss: "We could even automate a pipeline" for "I'm not saying we automate it"). gpt-oss absorbs it best and wins the most dictations, partly because Apple's breaks lead it to paragraphs (4 of 9 long answers split, 0 from Cohere), which the judge liked.
- **Twice the data made the 0.6B worse, not better**: v2 stopped looping (one doubled word in 40 answers against Heavy's 20, no fall-backs) but drops and invents more (17 faults, the long dictations worst). 520 examples of the same kind still teach style, not judgment; the 0.6B's size looks like the limit.
- **Verdict**: dictation stays on Cohere; Apple Speech is the fallback for an 8 GB Mac, with a rewrite, never Raw. The on-device rewrite stays the 4B. The next small-model try, if any, is a bigger student (Qwen3-1.7B), not more data for the 0.6B.
- Speed: gpt-oss on Apple's text 0.91 s median (0.39–6.4 s, OmniRoute noise); the 4B 1.17 s median; the 0.6B models 0.18 s.

## Qwen3-1.7B fine-tunes, judged blind (2026-10-16)

The bigger student the 0.6B study pointed to. LoRA on the app's own 4-bit `mlx-community/Qwen3-1.7B-4bit` (QLoRA: the full-precision download kept restarting), same recipe and data as Heavy 0.6B (262 training dictations, gpt-oss text that was pasted as the target, rank 8, all layers, lr 1e-4, batch 4, prompt masked), fused back to 4-bit (934 MB). Validation loss bottoms out at step 100: 0.33 (0.6B Heavy: 0.43). **Heavy + paragraphs** is the same with the 37 long targets split into paragraphs on this Mac by qwen3.6:27b (Ollama), kept only when the words came back unchanged (37 of 37; `tools/finetune/paragraphs.py`). Same blind judge set-up as above, 6 systems on the 40 held-out dictations:

| System | faithful | clean | professional | structure | mean rank (1 best) | rank, 80+ words | wins | serious faults |
|---|---|---|---|---|---|---|---|---|
| gpt-oss-120b (pasted) | 4.67 | 4.80 | 4.70 | 4.38 | 2.00 | 1.33 | 25 | 3 |
| Qwen3-4B, Clean prompt | 4.60 | 4.20 | 4.17 | 4.03 | 2.90 | 2.56 | 5 | 4 |
| 1.7B Heavy + paragraphs | 4.45 | 4.12 | 4.03 | 3.90 | 3.48 | 3.33 | 3 | 7 |
| 1.7B Heavy | 4.33 | 3.98 | 3.90 | 3.90 | 3.62 | 3.22 | 4 | 9 |
| Qwen3-1.7B, untrained, Clean prompt | 4.70 | 3.08 | 3.20 | 3.38 | 4.42 | 5.00 | 2 | 12 (10 "left uncleaned") |
| Heavy 0.6B | 4.12 | 3.67 | 3.52 | 3.80 | 4.58 | 5.56 | 1 | 13 |

Word error rate against the pasted text (`score.py`): 4B 31.4, Heavy + paragraphs 29.7, Heavy 33.2, untrained 1.7B 42.6, Heavy 0.6B 41.3. Median 0.47 s against the 4B's 1.14 s; peak 1.7 GB against 3.2 GB; no answer fell back to the heard text.

- **Training pays at 1.7B**: from last but one to third, faults 12 → 7, clean 3.08 → 4.12. The untrained 1.7B is faithful only because it barely changes anything.
- **Still short of the 4B**: 7 serious faults against 4, the same kinds as the 0.6B's but fewer: an invented question ("Is there any other step we need to take?"), questions turned into statements, a dropped request on a long dictation, garbled merges. Close enough on word overlap (29.7 vs 31.4) to show WER can't see this; the blind judge can.
- **Paragraphs weren't learned**: neither variant split any long dictation. Repeating the long examples 3× (one run coincided with a kernel watchdog panic on the M5 at batch 4; its batch-1 + grad-accumulation restart diverged, 43.0 WER, discarded) and a "…, in paragraphs." system line for dictations of 100+ heard words (batch 2) got 1–2 of 7 split. The paragraph-split targets still helped faithfulness and rank.
- **Verdict**: the on-device default stays the 4B. Heavy + paragraphs 1.7B is a better 8 GB-Mac model (D4) than the stock 1.7B, at half the 4B's memory and 2.4× its speed, but it still made 7 serious faults in 40 dictations against the 4B's 4.

### qwen3.6:27b as a teacher (2026-10-16)

More training data has to come from Notes transcripts, which never leave this Mac, so their targets would come from qwen3.6:27b on Ollama rather than gpt-oss. The 0.6B study showed that a 4B-level teacher makes a worse student, so the 27B was first judged blind against gpt-oss and the 4B on the same 40 held-out dictations. All three systems used the app's Clean prompt. The 27B also had the paragraph rule; the 4B's answers predate it (0 of 9 long answers split; the 27B split 2). Same judge brief, ranks 1–3:

| System | faithful | clean | professional | structure | mean rank (1 best) | rank, 80+ words | wins | serious faults |
|---|---|---|---|---|---|---|---|---|
| qwen3.6:27b, Clean prompt | 4.80 | 4.38 | 4.53 | 4.42 | 1.85 | 1.67 | 18 | 3 (2 "left uncleaned") |
| gpt-oss-120b (pasted) | 4.55 | 4.75 | 4.78 | 4.40 | 1.90 | 1.78 | 13 | 5 |
| Qwen3-4B, Clean prompt | 4.50 | 4.12 | 4.17 | 4.08 | 2.25 | 2.56 | 9 | 10 |

- **The 27B is a gpt-oss-level teacher, not a 4B-level one.** It is the most faithful of the three and ranks level with gpt-oss. It cleans less: gpt-oss is the heavier rewriter (clean 4.75 vs 4.38), and two of the 27B's faults left fillers such as "yeah, that's that's" and "anyways" in place. Its third fault invented an ending for an unfinished thought.
- The 4B made 10 faults here against 4 in the six-way judging. The same answers were compared against fewer, stronger systems, so the judge found more to mark. Read the fault counts within one table only.
- The 27B is slow (13 s median on the M5), which is fine for offline labelling only. The Notes pieces it labels (508 pieces, 36.6K words) can therefore join the gpt-oss pool as Heavy-style targets.

### 1.7B on dictations + 27B-labelled Notes pieces (overnight, 2026-10-17)

`finetune-17b` in `tools/overnight.sh`: Heavy + paragraphs' 262 dictations plus 482 of the 508 Notes pieces the 27B labelled (26 dropped as summaries, under 0.6× the heard words; `tools/finetune/build_notes_mix.py`), batch 2 × accumulation 2 with gradient checkpointing, 400 iterations. The validation set is the same 30 dictations as before.

| Model | val loss (best step) | WER | fmt WER | median s | peak MB |
|---|---|---|---|---|---|
| Heavy + paragraphs (`scribe-1.7b-qpara-4bit`) | 0.340 (100) | 29.7 | 32.1 | 0.48 | 1,733 |
| + Notes pieces (`scribe-1.7b-qnotes-4bit`) | 0.286 (375) | **41.4** | 44.3 | 0.49 | 1,733 |

- **Worse on dictation Clean, despite the lower validation loss.** Of the 40 held-out dictations, 22 got worse and 4 better. The answers ran 2,100 words against Heavy + paragraphs' 1,780 and the pasted text's 1,672: the model learnt to keep more of what was said ("It's just notes that I've been trying to take so far. Other places."). The 27B is the lighter cleaner (clean 4.38 vs gpt-oss 4.75 above), and its pieces outnumbered the dictations almost 2 to 1.
- **Not judged for Notes.** No held-out Notes pieces were scored, so whether it is a better *notes* cleaner is unknown. WER against gpt-oss's pasted text measures closeness to the heavy style, not quality, so this alone doesn't rule it out for Notes.
- **Verdict**: Heavy + paragraphs stays the 1.7B candidate for dictation. A Notes-specific student would need its own held-out Notes set and a blind judging round before it could ship.


### Notes tap vs hold, live harness (2026-10-17)

`tools/notes-taptest.py` runs the Debug app's `--notes-harness taps` (`Hex/App/NotesTapHarness.swift`) once per scenario on a scratch data root. The key events go through the real `startHotKeyMonitoringEffect` (a fake `KeyEventMonitorClient` delivers them), so `NotesTapDetector` and `HotKeyProcessor` run as in the app, with wall-clock timing. The held time is cut out of `qa-10min.wav` instead of recorded, and paste, sounds and the field reads are logged or empty. Transcription (Parakeet v3 for dictation), the Notes engine (Cohere, Silero, diarizer, on-device notes) and the rewrite are live. No production code changed. Hold dictations are cut from 60 s into the file, where one speaker is clear: at 55 s and 100 s the same check came back FAIL because Parakeet and Cohere disagree on crosstalk (the cut audio was byte-identical to the source).

| Scenario | Result | Evidence |
|---|---|---|
| Tap (held 0.16 s), second tap after 60 s | PASS | pasted 0, transcribes 0; one session, 59 s of audio in 3 chunks, 180 words, 4 speakers, stage `done` with notes written 8 s after the stop |
| Hold 4.2 s, Raw | PASS | 1 transcribe, 1 paste, no session folder; "dictating as" state reached 0.31 s after the press (one start sound); pasted "And I will use the llama to drive the truck all the way to my house.", Cohere reads the same (WER 0%) |
| Release at 0.27 s | PASS | session started, 20 words after a stop 6 s later |
| Release at 0.41 s | PASS | 1 recording stop, 1 transcribe, no `notes.start`, no Notes folder (the 0.4 s clip transcribed to nothing, so 0 pastes) |
| Tap, second tap 3.2 s in | PASS | `discard` 1, `stop` 0, Notes folder empty, nothing pasted |
| Hold 4.2 s, Clean picked before Notes | PASS | history entry `clean` by `Qwen3-4B-Instruct-2507-4bit`, raw text kept, key-up to paste 0.9 s |

Release times are the sleep's target plus a few milliseconds (0.25 asked, 0.27 measured), so the pair brackets the 0.3 s window by 30 ms and 110 ms. Not covered: the physical key and the event tap, and the pill and sounds as seen and heard.


## Phonon-2 (2026-10-17)

Fermion Research's 2.1-bit retrain of Parakeet TDT 0.6B v3 (English; weights CC-BY-4.0, derived from NVIDIA's parakeet-tdt-0.6b-v3). Two runtimes were measured: FluidAudio's Core ML port (`parakeet:phonon2`, in the app's FluidAudio) and Fermion's own Swift package `phonon-coreml` 1.1.2 (`fermion:phonon2`, `Transcriber`, lsbench only; it links the closed static library `PhononTDT.xcframework`). The Fermion model folder is `FermionResearch/Phonon-2-CoreML` (332 MB package + 13 MB `decoder.bin`, SHA-256 checked against its `SHA256SUMS`), in `<data root>/Models/fermion/Phonon-2-CoreML`. Its encoder has 5, 10, 15 and 35 s windows; all four were loaded before any timed clip. Raw JSON, the History clip sets (symlinks, with Cohere's text as `.txt`) and the per-pass logs are in `<data root>/bench/phonon/`.

Conditions: Apple M5, 24 GB, macOS 26.6.2, Release build of lsbench. The Mac was in use the whole time (load average 7–8), so single latencies carry noise; engines were run one after another, never together. "Footprint" is the process's peak physical footprint; Core ML/ANE memory is mostly outside it.

### Load time

| Runtime | First load ever | Warm load |
|---|---|---|
| Fermion `phonon-coreml` | **208.5 s** (3 min 28 s): `Transcriber.init` 54.4 s (15 s window, the ANE compile; `MLModel.compileModel` itself 0.64 s), then the 5, 10 and 35 s windows 154.1 s | 0.3–0.4 s init + 0.7–1.1 s for the other three windows = 1.1–1.2 s |
| FluidAudio port | not measured (already compiled on this Mac) | 0.2 s |

The compiled model is kept in `~/Library/Caches/phonon-coreml/<key>` (317 MB), so the first-load cost is paid once per path and configuration. Fermion's README says "a minute or two"; the default 15 s window alone took 54 s, the whole set 3.5 min. Peak footprint on that cold load was 172 MB.

### A. Accuracy and speed (3 warm runs per clip)

Real voice, `fixtures/me`: 20 clips, 3.7–9.8 s, 284 reference words.

| Engine | Corpus WER | S / D / I | Median latency | Per 10 s | Peak footprint | Warm load |
|---|---|---|---|---|---|---|
| Cohere 4-bit (MLX) | **5.28%** | 11 / 1 / 3 | 222 ms | 339 ms | 2,020 MB | 0.4 s |
| Parakeet v3 | 8.80% | 19 / 0 / 6 | 50 ms | 78 ms | 49 MB | 0.3 s |
| Phonon-2, FluidAudio port | 8.80% | 19 / 1 / 5 | 45 ms | 72 ms | 51 MB | 0.2 s |
| Phonon-2, Fermion runtime | 8.45% | 19 / 1 / 4 | **17 ms** | **24 ms** | 111 MB | 1.2 s |
| Apple SpeechTranscriber | 8.80% | 18 / 1 / 6 | 124 ms | 189 ms | 17 MB | 0.2 s |

Read-aloud lines, `calibration/`: 68 clips, median 3.8 s, 316 s in all, 593 reference words, jargon-heavy.

| Engine | Corpus WER | S / D / I | Median latency | Per 10 s | Lines with 0 errors | Peak footprint |
|---|---|---|---|---|---|---|
| Cohere 4-bit (MLX) | **4.72%** | 19 / 2 / 7 | 161 ms | 412 ms | 53 of 68 | 2,034 MB |
| Parakeet v3 | 6.75% | 28 / 1 / 11 | 42 ms | 104 ms | 46 | 61 MB |
| Phonon-2, FluidAudio port | 8.26% | 33 / 3 / 13 | 37 ms | 93 ms | 46 | 64 MB |
| Phonon-2, Fermion runtime | 8.77% | 32 / 1 / 19 | **9 ms** | **26 ms** | 46 | 122 MB |
| Apple SpeechTranscriber | 9.11% | 36 / 1 / 17 | 82 ms | 213 ms | 42 | 29 MB |

Both sets together (877 words): Cohere 4.90%, Parakeet v3 7.41%, Phonon-2 FluidAudio 8.44%, Phonon-2 Fermion 8.67%, Apple 9.01%.

Jargon: the 10 calibration lines that carry `terms` (20 terms). "As spelled" means the term appears in the hypothesis as the same word sequence; "ignoring spaces" lets "Swift UI" count for SwiftUI.

| Engine | As spelled | Ignoring spaces |
|---|---|---|
| Cohere 4-bit | 14 / 20 | 16 / 20 |
| Parakeet v3 | 12 / 20 | 14 / 20 |
| Phonon-2, FluidAudio port | 9 / 20 | 13 / 20 |
| Phonon-2, Fermion runtime | 9 / 20 | 13 / 20 |
| Apple Speech | 8 / 20 | 12 / 20 |

Missed by all five: equatable ("equitable"), SwiftUI ("Swift UI"), OmniRoute ("OmniRoot"/"Omniroot"), Syncthing ("sync"/"SINSING"/"sensing") and Ollama ("Olama"/"OLAMA"). macOS ("Mac OS", "MacOS14 .3") is missed by Cohere, v3 and both Phonon-2 runtimes but written right by Apple. Both Phonon-2 runtimes also miss three that v3 and Cohere write right: TypeScript ("type script"), OpenAPI ("open API") and kitchenettes ("Kitchenets"). SQLite and CLI ("SQL light", "CELI") are missed by v3, both Phonon-2 runtimes and Apple, not by Cohere. Apple additionally misses hotkey, synced, Tailscale, JSON and OpenAPI.

What the numbers say:
- On `fixtures/me` Phonon-2 is where v3 is: 8.80% (FluidAudio port, the 2026-10-06 figure reproduced) and 8.45% (Fermion), a one-word difference out of 284. On the jargon-heavy read-aloud lines it is behind v3 (8.26% and 8.77% against 6.75%, 9 and 12 more errors out of 593); Cohere is ahead of every Parakeet-family engine on both sets.
- The two Phonon-2 runtimes agree closely: same model, so most differences are single words. Fermion's 19 insertions on calibration against FluidAudio's 13 include a number written out in words ("port twenty thousand one hundred twenty-eight", where the port wrote "port20 128") and spacing ("every one").
- Phonon-2's extra errors against v3 on calibration sit on 8 lines, and are spelling and spacing: "every one", "Isle" for "Aisle", "type script", "version2 .4 .1", "Lans" for "Lawns", "dialogue". v3 writes more of the user's jargon as one word.
- Fermion's runtime is 2.6–4× faster than the FluidAudio port on short clips (17 ms against 45 ms on `me`; 9 against 37 ms on calibration) at about twice the process footprint (111–122 MB against 51–64 MB). Both are far under the 500 ms budget. Cohere is ~13× slower than Fermion on `me` and ~2 GB larger.
- Warm load is 1.1–1.2 s for Fermion against 0.2 s for FluidAudio; the first load on a machine is 3.5 min.

### B. Long audio (15 History recordings, 30–118 s, 854 s in all, 3 warm runs)

No references. "Agreement" is the WER with Cohere 4-bit's transcript of the same clip as the reference, so it measures how close an engine is to Cohere, not how right it is; "without um/uh" drops fillers from both sides (Cohere writes almost none).

| Engine | Median latency | Median RTFx | Total RTFx | Slowest clip | Agreement WER vs Cohere | … without fillers | Peak footprint |
|---|---|---|---|---|---|---|---|
| Parakeet v3 | 236 ms | 264× | 225× | 531 ms (40 s clip) | 7.16% | 6.40% | 131 MB |
| Phonon-2, FluidAudio port | 258 ms | 220× | 196× | 681 ms (73 s clip) | 7.78% | 7.02% | 147 MB |
| Phonon-2, Fermion runtime | **111 ms** | **546×** | **509×** | 199 ms (118 s clip) | 7.85% | 7.09% | 156 MB |
| Apple SpeechTranscriber | 476 ms | 111× | 106× | 999 ms (95 s clip) | **4.13%** | 3.72% | 85 MB |
| Cohere 4-bit (chunked as the app does) | 1,035 ms | 48× | 48× | 2,446 ms (118 s clip) | n/a | n/a | 2,563 MB |

What the numbers say:
- Fermion's latency grows slowly with length (74 ms at 37 s, 199 ms at 118 s); its 30–35 s clips, which use the single-shot 35 s window, took 111–116 ms, slower than the windowed 37–45 s ones (73–75 ms). v3 and the FluidAudio port take 127–681 ms across the same clips, with a few slow outliers (v3 531 ms at 40 s, port 681 ms at 73 s) that may be the busy Mac rather than the models (not re-run).
- The three Parakeet-family engines disagree with Cohere by 7–8%; Apple by 4%. 0.4–0.8 points of that is fillers Cohere leaves out (removed on both sides above).

### C. Live text simulation (`lsbench live`)

Every 0.4 s the prefix [0, t] is transcribed again, as a live caption (or `SpeechPeekClient`) would. Sets: `fixtures/me` (20 clips, 333 passes per engine) and 10 History recordings of 20–58 s (362 s, 909 passes per engine; reference = Cohere's text, so its WER is agreement). "First word" is the audio time plus the pass's latency of the first pass showing any text, from the clip start. "First correct word" is the same for the first pass whose first word is the reference's first word, counted from the speech onset (first 20 ms block above −40 dBFS; median 0.50 s in `me`, 0.46 s in the History clips). "Changed" is the number of already-shown words that the next pass changed or dropped (word-level edit alignment of consecutive passes), summed per clip; "settled" ignores the last two words of the older pass. Apple's passes include writing a temporary WAV and starting an analyzer each time.

`fixtures/me`:

| Engine | Pass latency (median / p95) | First word, from clip start | First correct word, from onset (median / p95) | Changed per clip (median, mean) | Settled changes (median, mean) | Final-pass WER |
|---|---|---|---|---|---|---|
| Parakeet v3 | 41 / 51 ms | 431 ms | 818 / 1,540 ms (19 of 20 clips) | 10, 11.1 | 4, 3.8 | 8.80% |
| Phonon-2, FluidAudio port | 37 / 49 ms | 425 ms | 409 / 872 ms (19) | 9, 10.2 | 2, 2.0 | 8.80% |
| Phonon-2, Fermion runtime | **10 / 19 ms** | 407 ms | 448 / 788 ms (19) | 4, 5.7 | 0, 0.8 | 8.45% |
| Apple Speech | 88 / 166 ms | 853 ms | 489 / 1,060 ms (19) | **2, 3.1** | **0, 0.6** | 8.80% |

History clips, 20–58 s:

| Engine | Pass latency (median / p95) | First word, from clip start | First correct word, from onset (median / p95) | Changed per clip (median, mean) | Settled changes (median, mean) | Final-pass agreement WER |
|---|---|---|---|---|---|---|
| Parakeet v3 | 103 / 290 ms | 432 ms | 1,086 / 2,112 ms | 18, 23.5 | 6, 9.0 | 9.82% |
| Phonon-2, FluidAudio port | 102 / 323 ms | 628 ms | 552 / 1,633 ms | 34, 39.2 | 8, 11.0 | 10.15% |
| Phonon-2, Fermion runtime | **75 / 118 ms** | 807 ms | 507 / 1,608 ms | 14, 25.4 | 3, 15.3 | 9.66% |
| Apple Speech | 204 / 523 ms | 848 ms | 549 / 1,659 ms | **10, 11.3** | **2, 2.6** | **6.55%** |

Pass latency by prefix length (median / p95 ms), History clips; `me` has only the first two rows (v3 39 / 47 and 47 / 51, port 34 / 43 and 44 / 50, Fermion 9 / 12 and 18 / 20, Apple 71 / 117 and 127 / 194):

| Prefix | Parakeet v3 | Phonon-2 port | Phonon-2 Fermion | Apple |
|---|---|---|---|---|
| 0–5 s | 38 / 73 | 33 / 39 | 8 / 12 | 61 / 96 |
| 5–10 s | 46 / 57 | 43 / 71 | 17 / 22 | 117 / 155 |
| 10–20 s | 84 / 135 | 86 / 233 | 74 / 110 | 181 / 270 |
| 20–40 s | 131 / 342 | 127 / 337 | 110 / 124 | 308 / 452 |
| 40+ s | 163 / 382 | 275 / 348 | 77 / 99 | 522 / 651 |

Text shown before anyone has spoken: of the passes that end before the speech onset, Parakeet v3 shows text in 13 of 17 (13 of 20 `me` clips affected), the FluidAudio port in 14 of 17 (13 of 20), Fermion in 12 of 17 (10 of 20) and Apple in 0 of 17. Typical text is "Yeah." or "Okay." and goes away on a later pass. In the History clips: v3 5 of 10 clips, port 3, Fermion 3, Apple 0.

The "Legacy"/"Lucy" early check: the first 1.0, 1.7, 2.5 and 3.3 s of 16 History recordings whose heard text starts with Legacy or Lucy (`SuperTrigger.earlyVerdict` applied to what each engine writes; "trigger word first" = the first written word is legacy or lucy; "flash" = the verdict is isSuper, which asks for a pause mark after the word; "other" = text whose first word is not the trigger). At 1.0 s Apple writes nothing for 9 of the 16 clips (the word is not yet said, or is cut off), so every engine has little to read then.

| Engine | First N s | Trigger word first | Flash (isSuper) | Undecided | Other text | Empty | Median latency |
|---|---|---|---|---|---|---|---|
| Parakeet v3 | 1.0 / 1.7 / 2.5 / 3.3 | 4 / 12 / 16 / 16 | 3 / 10 / 12 / 11 | 0 / 0 / 1 / 0 | 1 / 1 / 0 / 0 | 11 / 3 / 0 / 0 | 30–37 ms |
| Phonon-2, FluidAudio port | same | 7 / 14 / 15 / 16 | 4 / 9 / 12 / 12 | 1 / 2 / 0 / 0 | 6 / 2 / 1 / 0 | 3 / 0 / 0 / 0 | 26–32 ms |
| Phonon-2, Fermion runtime | same | 7 / 14 / 16 / 15 | 2 / 5 / 7 / 9 | 1 / 6 / 5 / 3 | 5 / 1 / 0 / 1 | 4 / 1 / 0 / 0 | 7–8 ms |
| Apple Speech | same | 7 / 15 / 16 / 16 | **6 / 15 / 16 / 16** | 0 | 0 | 9 / 1 / 0 / 0 | 40–62 ms |
| Cohere 4-bit | same | 7 / 15 / 16 / 16 | 6 / 14 / 13 / 15 | 0 | 9 / 1 / 0 / 0 | 0 | 98–144 ms |

No engine flashed on a result whose first word was not the trigger (0 false flashes in 64 checks per engine). The "other text" at 1.0 s is mostly "Yeah." (the three Parakeet-family engines) or "Thank you." (Cohere, 9 of 16 clips) over speech that hasn't begun. The Parakeet family writes "Legacy" without the comma or full stop `earlyVerdict` looks for far more often than Apple does ("Legacy now make this", "Legacy fix"), so its flash count trails its trigger-word count; Of the trigger-first results, the ones that did not flash: Apple 1 of 54, Cohere 6 of 54, v3 12 of 48, port 15 of 52, Fermion 29 of 52.

What the numbers say:
- Fermion's runtime has the lowest pass latency of the four at every prefix length (8–12 ms to 5 s, ~110 ms at 20–40 s); Apple's grows from 61 to 522 ms with the prefix, the Parakeet-family engines in between.
- Stability: Apple's text changes least (a median 2 shown words per `me` clip, 10 per History clip). Fermion's changed words on `me` are the lowest of the Parakeet family (median 4, settled 0), but on the History clips two clips dominate its mean (the 29 s clip: 49 settled changes, the 58 s clip: 79; v3 8 and 25 on the same clips). The cause was not investigated.
- Parakeet-family engines show a phantom word ("Yeah.", "Okay.") before speech in 10–13 of the 20 `me` clips and 3–5 of the 10 History clips; Apple never does, and Cohere writes "Thank you." on leading silence.
- Time to the first correct word is ~0.4–0.55 s after speech onset for Phonon-2 (both runtimes) and Apple on `me`, 0.8 s for v3; on long dictations all four are at 0.5–1.1 s median.

### D. Word timings (`lsbench align --tts --engine`)

Same method as "Word timings" above: 120 practice lines, 879 synthesized words with exact boundaries, each engine's own word timings moved onto the line's words (`WordMatcher.transfer`). v2 is a sanity check: it reproduces the table above (72 ms / 55% raw, 51 ms / 77% shifted).

| Engine | Start, as the engine gives it (median off / p90 / within 80 ms) | Start with the app's +80 ms shift | End (median / p90 / within 80 ms) |
|---|---|---|---|
| Parakeet v2 (check) | 72 ms / 146 / 55% (signed −68) | 51 ms / 113 / 77% | 90 ms / 187 / 43% |
| Parakeet v3 | 95 ms / 166 / 41% (signed −95) | 45 ms / 107 / **82%** | 98 ms / 205 / 40% |
| Phonon-2, FluidAudio port | 60 ms / 125 / 73% (signed −60) | 38 ms / 93 / **84%** | 156 ms / 274 / 21% (signed −125) |
| Phonon-2, Fermion runtime | **36 ms / 89 / 85%** (signed +20) | 100 ms / 165 / 27% | 114 ms / 233 / 34% (signed −56) |

- Fermion's own word starts need no shift (the shift pushes them 100 ms late). Like v2 and v3, the FluidAudio port's starts run early (signed −60 ms) and gain from the +80 ms shift.
- Ends are loose for every engine (21–43% within 80 ms); the FluidAudio port's are the loosest, a median 125 ms early.

### E. Fillers on 40 History recordings (`lsbench fillers`)

40 recordings of 15–118 s picked at random (1,820 s). Fillers are counted by `CoachText.analyse` (um, uh, er, ah, hmm and their spellings, e.g. "mm") on each engine's text split at spaces. No by-ear count was made for these clips.

| Engine | Words | Fillers | Per 100 words | Clips with a filler | By kind |
|---|---|---|---|---|---|
| Cohere 4-bit | 2,869 | 0 | 0 | 0 | none |
| Parakeet v3 | 3,010 | 24 | 0.80 | 17 | um 16, uh 7, mm 1 |
| Phonon-2, FluidAudio port | 3,004 | 23 | 0.77 | 17 | um 17, uh 5, mm 1 |
| Phonon-2, Fermion runtime | 3,014 | 25 | 0.83 | 18 | um 17, uh 8 |
| Apple Speech | 2,944 | 18 | 0.61 | 15 | um 15, uh 3 |

Against Parakeet v3's count per clip: the FluidAudio port differs on 1 of 40 clips, Fermion on 3, Apple on 5, Cohere on 17 (it wrote none). Seven clips are counted differently by at least one of the four verbatim engines. Five of them:

- `1791898562`: "…not in **uh** at least the bare text" is written by v3 and Fermion, left out by the port and by Apple ("…not in at least the bare text"); all four write "we can see uh if it says height and width".
- `1791947630`: "…for the beta test. **Um** just have it more as an…" in v3, the port and Fermion; Apple writes no filler.
- `1791947884`: Fermion adds "as there's a thing s **uh** like a disclaimer"; the other three write only "without um double checking".
- `1792106997`: v3 and the port write 3 ("Mm when I mentioned the notes, um the notes ID…", "this uh new change"); Fermion writes 2 (no "Mm"); Apple writes 1 (only "um").
- `1792186129`: Fermion alone writes "…when it's time to **Uh** yeah, I don't know."

What the numbers say:
- v3, the port and Fermion give the same count on 36 of 40 clips and are within one filler on the other four; they total 23–25 fillers, Apple 18, Cohere 0.
- Fermion wrote the most fillers (25); the ones it alone added are "as there's a thing s uh like a disclaimer" and "time to Uh yeah", and it left out the "Mm" that v3 and the port wrote on 1792106997.

### F. Noise (`fixtures/me` with noise added; 1 run, WER)

Pink noise (1/f, seeded) and a babble track (three `say` voices, Samantha, Daniel and one requested as Alex, reading different passages, summed; a random stretch per clip) added to each of the 20 clips at 10 and 5 dB SNR. SNR is the clip's active-speech power (20 ms blocks above −45 dBFS) over the noise's power; clips that would clip are scaled down together with the noise. One noise realisation per cell, so a cell moves 0.35 points per word. Files are in `<data root>/fixtures/me-noise-{pink,babble}-{10,5}/`.

| Engine | Clean | Pink 10 dB | Pink 5 dB | Babble 10 dB | Babble 5 dB |
|---|---|---|---|---|---|
| Cohere 4-bit | **5.28%** | **8.45%** | **14.08%** | **7.39%** | **22.18%** |
| Parakeet v3 | 8.80% | 11.62% | 14.08% | 14.08% | 42.61% |
| Phonon-2, FluidAudio port | 8.80% | 11.62% | 16.90% | 15.85% | 31.69% |
| Phonon-2, Fermion runtime | 8.45% | 10.92% | 16.20% | 15.14% | 31.34% |
| Apple SpeechTranscriber | 8.80% | 15.49% | 25.00% | 21.83% | 65.14% |

What the numbers say:
- The two Phonon-2 runtimes degrade alike. Against v3 they are a little worse in pink noise at 5 dB (16.2–16.9% against 14.1%) and in babble at 10 dB (15.1–15.9% against 14.1%), and much better in babble at 5 dB (31.3–31.7% against 42.6%), where Cohere stays at 22.2%.
- Apple is the least robust in every noisy cell (65% at babble 5 dB); Cohere is the best in every cell (tied with v3 at pink 5 dB).

### Caveats

- One machine, a busy one, one run per question; the History sets are 10–40 of the user's recordings, and the 16 trigger clips are the same ones the Legacy feature was tuned on.
- Sections B and C use Cohere's transcript as the reference for History clips; agreement is not accuracy, and Cohere drops fillers and hesitations the others write.
- The phantom words before speech, the "first word" figure and the onset all depend on the −40 dBFS onset estimate; compare engines with each other, not with a ground-truth latency.
- The FluidAudio port's cold compile was not measured; the Fermion runtime's cold load (208 s) was measured once.
- Fermion's runtime is closed source below the Swift layer (`PhononTDT.xcframework`); nothing here is linked into the app.

## Live captions: Apple streaming (2026-10-17)

Question: does SpeechAnalyzer's own streaming (volatile results) beat the prefix mode in section C above (the whole clip so far transcribed again every 0.4 s) for live text in the recording capsule, and how stable is a display that shows only settled words? `lsbench live --engine apple --stream` (`LiveStreamBench.swift`).

Conditions: Release lsbench, macOS 26.6.2, a busy Mac, one run per variant and set, audio fed at 1× real time. `SpeechTranscriber(locale: en-US, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])`, once as is and once with `.fastResults` added (it exists in the macOS 26 SDK swiftinterface). The clip goes to `SpeechAnalyzer.start(inputSequence:)` as 100 ms `AnalyzerInput` buffers in the analyzer's own best format (16 kHz Int16), and the stream ends with `finalizeAndFinish(through:)`. At the exact end of the audio that call never returned; 10 ms before it works, so the last 10 ms are not counted as finalized by it. The analyzer is prepared before the feed starts and a 3 s clip is run first, so no model load is timed. Each result is stamped with the wall time since the first buffer (= audio time at 1×). No Silero gate. Sets as in section C: `fixtures/me` (20 clips, 130 s, 288 words) and the 10 History clips of 20–58 s (362 s, about 630 words, Cohere's text as reference, so WER there is agreement). Onset is the same −40 dBFS estimate as before (median 0.50 s and 0.46 s).

What is scored:
- Displays, all from the same results: **raw** = every finalized result so far + the newest volatile one; **settled-2** = finalized + the volatile words except the last two; **stable-2** = finalized + the leading volatile words that the previous update also had. The comparison with the prefix mode is on the display sampled every 0.4 s, like its passes. Several results often arrive within a few milliseconds of each other (a burst, each text one word longer); a caption can only show the last, so only that one is scored.
- "Changed" and "settled" are `changedWords` as in section C (shown words that the next sample changed or dropped; settled = not counting the last two words). Per 100 words = per 100 final words of the set.
- "First word, from clip start" is when any display has text; "first correct word" is the first display whose first word is the reference's first word, counted from the onset.

`fixtures/me` (prefix row = section C):

| Mode | Display | First word, from clip start | First correct word, from onset (median / p95) | Changed per clip (median, mean) / per 100 words | Settled changes (median, mean) / per 100 words | Final WER |
|---|---|---|---|---|---|---|
| Prefix every 0.4 s | – | 853 ms | 489 / 1,060 ms (19 of 20) | 2, 3.1 / 21.5 | 0, 0.6 / 3.8 | 8.80% |
| Volatile | raw | 3,916 ms | 3,431 / 3,595 ms (19) | 0, 0.1 / 0.3 | 0, 0.0 / 0.0 | 8.45% |
| Volatile | settled-2 | 3,916 ms | 3,431 / 3,595 ms (19) | 0, 0.0 / 0.0 | 0, 0.0 / 0.0 | same |
| Volatile + fast | raw | 1,013 ms | 650 / 1,568 ms (19) | 1, 0.9 / 6.6 | 0, 0.1 / 0.3 | 9.15% |
| Volatile + fast | settled-2 | 1,910 ms | 1,486 / 2,387 ms (18) | 0, 0.1 / 0.3 | 0, 0.1 / 0.3 | same |
| Volatile + fast | stable-2 | 1,907 ms | 1,009 / 1,626 ms (18) | 0, 0.1 / 0.3 | 0, 0.1 / 0.3 | same |

History clips, 20–58 s:

| Mode | Display | First word, from clip start | First correct word, from onset (median / p95) | Changed per clip (median, mean) / per 100 words | Settled changes (median, mean) / per 100 words | Final agreement WER |
|---|---|---|---|---|---|---|
| Prefix every 0.4 s | – | 848 ms | 549 / 1,659 ms | 10, 11.3 / 18.0 | 2, 2.6 / 4.1 | 6.55% |
| Volatile | raw | 3,915 ms | 3,434 / 3,838 ms | 1, 1.7 / 2.7 | 1, 1.3 / 2.1 | 6.55% |
| Volatile | settled-2 | 3,916 ms | 3,434 / 3,838 ms | 1, 1.6 / 2.5 | 0, 1.1 / 1.7 | same |
| Volatile + fast | raw | 1,011 ms | 570 / 1,910 ms | 3, 2.7 / 4.3 | 0, 0.6 / 0.9 | 5.24% |
| Volatile + fast | settled-2 | 1,911 ms | 1,469 / 2,833 ms | 0, 0.6 / 0.9 | 0, 0.6 / 0.9 | same |
| Volatile + fast | stable-2 | 1,909 ms | 1,231 / 2,833 ms | 0, 0.7 / 1.1 | 0, 0.6 / 0.9 | same |

Timing of the results (all 30 clips; no pass latency exists in streaming, the figures are when text arrives):

| Mode | Results per second of audio (bursts / s) | Finalized word lag, arrival − end of the word (median / p95), `me` | same, History clips | Volatile text ahead of the finalized text, History clips (median / p95 / max) | After the last buffer, results complete |
|---|---|---|---|---|---|
| Volatile | 0.36 (131 in 362 s) | 3.1 / 6.7 s | 6.1 / 18.8 s | 7.3 s, 11 words / 19.3 s, 32 words / 27.0 s | 73 ms median, 109 ms p95 |
| Volatile + fast | 0.93 (335 in 362 s) | 3.1 / 6.6 s | 4.7 / 17.7 s | 4.9 s, 10 words / 17.4 s, 27 words / 25.9 s | 36 ms median, 171 ms p95 |

Text before speech onset: none, in any of the 46 clips and either variant (prefix mode: Apple 0 too).

"Legacy"/"Lucy" early check on the 16 trigger clips (`SuperTrigger.earlyVerdict` on the display at each moment; prefix "heads" row from section C for comparison). The clips all start with the trigger, so false flashes were not tested.

| Mode | isSuper at 1.0 / 1.7 / 2.5 / 3.3 s | First isSuper, from clip start (median / p95) |
|---|---|---|
| Prefix heads, Apple | 6 / 15 / 16 / 16 | – (60 ms pass) |
| Volatile, raw (settled-2 and stable-2 the same) | 0 / 0 / 2 / 3 | 3,913 / 3,923 ms (16 of 16) |
| Volatile + fast, raw | 0 / 3 / 8 / 12 | 2,127 / 3,907 ms (15 of 16) |
| Volatile + fast, stable-2 | 0 / 2 / 8 / 12 | 2,127 / 3,919 ms (15 of 16) |
| Volatile + fast, settled-2 | 0 / 1 / 6 / 11 | 2,910 / 3,919 ms (15 of 16) |

What the numbers say:
- `.volatileResults` alone is not live. Results come in bursts about every 3–4 s of audio (the first one at 3.9 s of audio, whatever the clip), so the first word shows 3.4 s after the speech starts on all 46 clips. It is stable because it updates so rarely. Not usable for captions.
- With `.fastResults` the first correct word is 650 ms (`me`) and 570 ms (History) after the onset, against 489 and 549 ms for the prefix mode: the same to within the noise of one run. Results arrive about once a second, each within ~0.1 s of the audio it covers, so nothing grows with the clip's length, unlike the prefix pass (61 ms to 522 ms). The cost is the update rate: a caption moves once a second, the prefix mode every 0.4 s.
- Fast raw text changes less than the prefix mode: 6.6 and 4.3 shown words changed per 100 words against 21.5 and 18.0. Almost all of it is in the last two words (settled changes 0.3 and 0.9 per 100, against 3.8 and 4.1 for the prefix mode). Dropping the last two volatile words removes the tail churn and leaves 0.3 and 0.9 per 100, at a price of about 0.85 s (`me`, 1,486 against 650 ms) to 0.9 s (History) on the first correct word and one more second of delay on every word. Stable-2 costs less, 0.36 s (`me`) and 0.66 s (History) on the first word, and changes as few words. The 0.3–0.9 per 100 that remain are words deeper than the tail that a later result rewrote; they are 2 and 6 words in the whole of each set.
- Finalized text alone cannot be the display: finalized words arrive 3 s (`me`) to 5–6 s (median, History) after they were said, 18 s at p95, and the volatile text runs a median 5 s (p95 17 s, up to 26 s) ahead of it, because Apple finalizes at sentence and pause boundaries (44 finalized results in 362 s). A caption has to show volatile words.
- For the "Legacy" early check streaming is worse than the prefix peek: 0 / 3 / 8 / 12 clips flash at 1.0 / 1.7 / 2.5 / 3.3 s against 6 / 15 / 16 / 16, because the first volatile text appears about 1 s after the onset. Keep the peek for that.
- Final WER differs between the three Apple runs of the same audio (8.80% prefix, 8.45% volatile, 9.15% fast on `me`: 2–4 words of 288), so those differences are noise at one run. Nothing here shows that streaming writes the final text worse.

Caveats: one run per variant and set, so the changed-word counts of a single clip (up to 10) move from run to run. The prefix rows are from the earlier run in section C, not repeated. "Results per second" counts bursts (results within 10 ms of each other count once). The word times Apple gives for volatile text are for the whole result, so the lag figures use the result's range for volatile text and each word's own range for finalized text. Settled-2 and stable-2 are two simple rules, not tuned.

### Confidence on the live words (2026-10-17)

Question: can a live caption show only the high-confidence volatile words (dimmed), hide the low-confidence ones, and turn words solid once confirmed? `lsbench live --engine apple --stream --fast --confidence` adds `.transcriptionConfidence` to `attributeOptions` (the run attribute `AttributeScopes.SpeechAttributes.ConfidenceAttribute`; a word takes the lowest value of the runs it sits in) and writes every result's words with their confidence, arrival time and burst flag to `bench/phonon/live-apple-stream-confidence-{me,hist-live10}.json`. `lsbench live --engine apple --stream --rescore <json>` scores those files again with no rerun. Same conditions as above (Release, `.volatileResults + .fastResults`, 1× real time, one run per set, sets `fixtures/me` and `bench/phonon/sets/hist-live10`; the brief's `sets/me` does not exist, `fixtures/me` is the 20 clips of the table above). The run reproduced the earlier one: final WER 9.15% and 5.24%, raw display 6.6 and 4.3 changed words per 100.

**Volatile results carry no confidence.** Not one of the 3,826 volatile words (`me`) and 8,856 (History) had a value, and a quick check without `.fastResults` (plain `.volatileResults`, two clips) gave none either. Final results always do:

| Results | Words | With confidence | Distinct values | Median | p10 | Share under 0.7 |
|---|---|---|---|---|---|---|
| Volatile, `me` / History | 3,826 / 8,856 | 0% / 0% | – | – | – | – |
| Final, `me` | 288 | 100% | 81 | 1.00 | 0.81 | 4.8% |
| Final, History | 632 | 100% | 201 | 0.99 | 0.69 | 10.6% |

So the three-tier display with a confidence threshold (T = 0.3 / 0.5 / 0.7 / 0.9) cannot be built from this API and was not scored. Confidence only arrives when a word is already final, which is the moment the caption turns it solid anyway.

What can be scored is the position rule. Each volatile word shown at one update, judged by whether the next visible update (the last result of a burst) changed or dropped it (same alignment as `changedWords`):

| Position from the end of the volatile text | `me`: changed / shown | History: changed / shown |
|---|---|---|
| Last word | 17.0% (23 / 135) | 7.2% (22 / 304) |
| 2nd last | 0.8% (1 / 129) | 0.4% (1 / 284) |
| Deeper | 0.9% (9 / 981) | 0.2% (7 / 2,875) |
| All | 2.7% (33 / 1,245) | 0.9% (30 / 3,463) |

Displays on the 0.4 s sampling, same metrics as the table above. Solid **A** = finalized words only; solid **B** = finalized plus the leading volatile words the previous update also had (the stable-2 rule). Dim = the volatile words that are not solid. With no confidence to hide by, nothing is hidden except in the first row, where the volatile words deeper than the last two (when not solid) would be hidden along with everything after them; that row shows the same text as the other two in both sets (the hide rule never fired), so all three rows read the same.

| Set | Display | First correct word, from onset (median / p95) | Changed per 100 words | Settled per 100 | Dim share of shown words (median / mean) | Dim words later changed | Solid words later changed |
|---|---|---|---|---|---|---|---|
| `me` | A, every volatile word dim | 648 / 1,570 ms (19 of 20) | 6.6 | 0.3 | 100% / 99% | 19 | 0 |
| `me` | B, rest dim (and B + dim last two) | 648 / 1,570 ms (19 of 20) | 6.6 | 0.3 | 12% / 20% | 18 | 1 |
| History | A, every volatile word dim | 572 / 1,910 ms (10 of 10) | 4.3 | 0.9 | 31% / 45% | 27 | 0 |
| History | B, rest dim (and B + dim last two) | 572 / 1,910 ms (10 of 10) | 4.3 | 0.9 | 3% / 7% | 20 | 7 |

For comparison, from the first run: B with the last two words withheld (stable-2) has the first correct word at 1,012 ms (`me`) and 1,233 ms (History) and 0.3 and 1.1 changed per 100.

What the numbers say:
- There is no confidence on volatile words, in either variant: the attribute is only filled in once a result is final. A caption cannot dim or hide by confidence, so "show only high-confidence words" has nothing to act on.
- Position already predicts change. The last volatile word changes 17% (`me`) and 7% (History) of the time at the next update; the second last 0.8% and 0.4%; deeper words 0.9% and 0.2%. The risk sits in the last word, not the last two. Dimming exactly one word would cover 23 of the 33 changes in `me` and 22 of 30 in History (70% and 73%).
- Under solid A the caption is mostly dim: in `me` a median 100% of the shown words (the short clips mostly get one final result, at the end) and in History 31% (finals arrive at pauses). Under solid B, where words turn solid once the next update repeats them, the dim part shrinks to a median 12% (`me`) and 3% (History): typically the last word or two. B is the one to use if anything is dimmed.
- Dimming changes how the caption looks, not what it says: the text and so the first correct word (648 and 572 ms, the same as the raw display) are unchanged, and the 6.6 and 4.3 changed per 100 words are still there, but now 18 of 19 and 20 of 27 of them fall on dim words. The 1 and 7 that fall on words B had made solid are the settled changes of the earlier table (0.3 and 0.9 per 100).
- Waiting for words to be final is not an option: they arrive a median 3.0 s (`me`) and 4.7 s (History) after being said (p95 6.6 and 17.7 s), so "solid once confirmed" has to mean "repeated by the next update", not "finalized".

Caveats: one run per set. The change rate counts a word every time an update shows it, so one long-lived word contributes several observations; rates are per observation, not per word. A "change" is the next update only, not any later one. Confidence on final words was not tied to errors (no check against the reference here). The "no confidence" result was seen on macOS 26.6.2 with the en-US model only. The stable-2 rule compares with the previous result, burst members included, so inside a burst nearly all words but the newest count as stable.

## Live caption in the app (2026-10-17)

DESIGN.md "Live caption", item 9. The caption is a second consumer of the capture tap (`SuperFastCaptureController.recordingSamples()` -> `LiveCaptionClient` -> `LiveCaption.apply` -> `TranscriptionFeature.caption`), started at `.microphoneReady` and cancelled at key-up. There is no microphone in the build session, so the audio is `fixtures/me` clips fed to the real client at 1x in 2,048-sample chunks (a tap buffer), through the reducer, with the setting on (`HexTests/LiveCaptionTests`; logs in `/tmp/live-caption-feed.log` and `/tmp/live-caption-budget.log`). Debug build, M5, a busy Mac, one run per row. Live-only numbers are marked not measured.

**First word and final text** (clips 01-05, each followed by 2 s of silence as a pause before key-up; caption text is what `store.caption` showed, polled every 128 ms):

| Clip | Speech onset | First word | After onset | Updates | Settled caption vs the clip |
|---|---|---|---|---|---|
| 01 | 1.04 s | 2.05 s | 1.01 s | 6 | identical |
| 02 | 0.60 s | 1.15 s | 0.55 s | 4 | "lunchunche" for "lunch", "10" for "ten", "I'll" for "I will" (3 errors) |
| 03 | 0.42 s | 1.16 s | 0.74 s | 4 | identical |
| 04 | 0.76 s | 2.05 s | 1.29 s | 5 | identical |
| 05 | 0.42 s | 1.16 s | 0.74 s | 5 | identical |

Median 0.74 s after the onset (bench: 650 ms), max 1.29 s; 3 word errors in 72, all on clip 02 (digits and contractions count as errors). The analyzer was prepared in 14-72 ms, so the delay is Apple's: fast results arrive on whole seconds of audio (ranges 0-2.0, 0-3.0, 0-4.0), and a word that starts just after a boundary waits for the next one (clip 04: speech at 0.76 s, first result at 2.05 s). The spec's "within 1.2 s of onset" therefore holds for the median, not for every clip: clip 04 is 1.29 s. The test asserts median <= 1.2 s and max <= 1.6 s. After key-up nothing stays on screen (asserted); in Notes mode a tap cancels the caption before any word (`testANotesTapCancelsTheCaptionBeforeAnyWord`).

**CPU** (60 s of fixture speech streamed at 1x through the reducer): 0.76 s of process CPU in 60.0 s = **1.3% of one core**, 51 caption changes. This is the whole test process, so the app's share is no more. The recognition itself ran in-process: over a 35 s feed no other process (corespeechd, XPC services) gained more than 0.3 s of CPU. With the Legacy peek also on: not measured (the peek only runs for the first 3.3 s; needs a live dictation).

**Key-up cost.** `store.send(.cancel)` with the caption streaming (the caption's part of key-up is the same `.cancel(id:)`), main actor, 10 runs after 2 s of audio: median 14.6 ms with the caption on against 11.6 ms off (max 18.8 / 14.1), so +3 ms in a Debug build, under the 20 ms budget. This is main-actor time of one `send`, not `DictationLatency`'s key-up to paste. The analyzer's shutdown (`cancelAndFinishNow`) after the consumer stops took a median of 1 ms (max 1 ms, 5 runs) and runs off the path anyway.

**Private mode.** `testCaptionOpensNoSocketInPrivateMode`: with `NetworkPolicy` private, a clip captioned through the live client showed text, no request was blocked and no internet socket opened (sampled every 10 ms). `PrivateModeTests` passes with the setting on (it is the default).

**Not measured (needs a person speaking):** `startup=` in the log (the caption starts after `.microphoneReady`, so nothing changes by construction), `DictationLatency` median over 10 real dictations caption on vs off, first word on the first dictation after launch (the first clip above includes the analyzer's first start in the process, 1.01 s, but not a cold launch), the whole app's CPU under Activity Monitor, and the two analyzers (peek + caption) together in the first 3.3 s.
