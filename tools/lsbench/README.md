# lsbench

Headless speech-to-text benchmark. For each fixture clip it reports median latency over N warm runs, real-time factor (RTFx = audio seconds ÷ processing seconds), and word error rate against a reference transcript. For the engine it reports load time and peak memory footprint.

## Build

MLX needs its Metal shader library, which only `xcodebuild` produces, and Xcode 26 needs the Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`, once). On a slow link, run `tools/spm-shallow-mirrors.sh` first and build inside `eval "$(../spm-shallow-mirrors.sh --git-env)"`.

```bash
cd tools/lsbench
xcodebuild -scheme lsbench -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/lsbench-dd build
alias lsbench=/tmp/lsbench-dd/Build/Products/Release/lsbench
```

## Fixtures

A fixture is `<name>.{wav,m4a,flac,caf,mp3}` plus an optional `<name>.txt` holding the exact words spoken. WER is computed after lowercasing and stripping punctuation.

- Synthetic baseline: `./make-say-fixtures.sh` writes four `say` clips (2–24 s) to `~/Library/Application Support/LegacyScribe/fixtures/say/`.
- Your voice (the numbers that matter): `tools/lsbench/record-voice-fixtures.sh` walks you through the 20 sentences in `voice-prompts.txt` (press Enter to start and stop each clip) and writes `01.wav`/`01.txt`… to `~/Library/Application Support/LegacyScribe/fixtures/me/`. Add your own clips with matching `.txt` files there too, especially names and jargon you actually dictate.

## Run

```bash
F="$HOME/Library/Application Support/LegacyScribe/fixtures/say"
M="$HOME/Library/Application Support/LegacyScribe/Models/mlx/beshkenadze"

lsbench --engine "cohere:$M/cohere-transcribe-03-2026-mlx-4bit" --fixtures "$F" --runs 5 --json cohere-4bit.json
# Cohere audio is cut like the app (CohereChunks: one pass up to 30 s, else even pieces of ≤ 24 s ± 3 s at quiet points); --cohere-chunk N uses mlx-audio's own splitter every N s (1200 = one pass)
lsbench --engine parakeet:v3 --fixtures "$F"        # also: parakeet:v2, parakeet:ultra, parakeet:phonon2
lsbench --engine fermion:phonon2 --fixtures "$F"    # Phonon-2 through Fermion Research's own runtime (see below)
```

`fermion:phonon2` runs Fermion's Swift package `phonon-coreml` 1.1.2 (`Transcriber`; it links a closed static library, so it is in lsbench only, never the app) on the model folder `~/Library/Application Support/LegacyScribe/Models/fermion/Phonon-2-CoreML`. `tools/fetch-hf.sh` lists only the top level of a repo, so fetch the model files with curl (the python files and the source tarball aren't needed), then check them against `SHA256SUMS`:

```bash
D="$HOME/Library/Application Support/LegacyScribe/Models/fermion/Phonon-2-CoreML"; U=https://huggingface.co/FermionResearch/Phonon-2-CoreML/resolve/main
mkdir -p "$D/Phonon-2.mlpackage/Data/com.apple.CoreML/weights" && cd "$D"
for f in SHA256SUMS manifest.json decoder.bin NOTICE LICENSE-WEIGHTS-CC-BY-4.0.txt Phonon-2.mlpackage/Manifest.json \
         Phonon-2.mlpackage/Data/com.apple.CoreML/model.mlmodel Phonon-2.mlpackage/Data/com.apple.CoreML/weights/weight.bin; do
  curl -fsSL -C - -o "$f" "$U/$f"; done
sed 's#\./##' SHA256SUMS | grep -E 'decoder|manifest|NOTICE|LICENSE-WEIGHTS|mlpackage' | shasum -a 256 -c
```

The first load compiles the encoder for the Neural Engine (3.5 min measured for all four windows, 54 s for the default 15 s one) and keeps the result in `~/Library/Caches/phonon-coreml`; later loads take about 1 s. lsbench loads all four windows (5, 10, 15, 35 s) up front and prints the split to stderr (`fermion load: init … other functions …`).

Notes speech gate: `lsbench vad [--engine cohere:<dir>] <wav or folder>...` prints what Silero VAD, with the app's notes settings, keeps of each clip. With `--engine`, each clip is also transcribed whole and gated, to compare what silence or noise turns into.

On-device rewrite: `lsbench rewrite --model <mlx-dir> --samples <file.jsonl> [--json out.json] [--no-think]` runs the app's rewrite prompts through an MLX model. Each sample line is `{"mode": "clean"|"prompt", "transcript": "…", "reference": "…"}`. Pass `--no-think` for Qwen3's hybrid models (1.7B, 8B). `samples/self-correction.jsonl` checks the self-correction rule (Clean corrections, lookalikes, Prompt corrections). A `"mode": "s1"` line runs S1-mini's fixed normalizer prompt (optional `"control"` line, greedy; pass `--no-think`). A `"mode": "chat"` line sends its `"system"` text and the transcript (for fine-tuned models). "s1" and "chat" answers are capped at 2.5 × the heard words + 64 tokens and retried once with repetition penalty 1.1 if they hit it. `"append"` adds text to a clean/prompt sample's system message, and `--messages out.jsonl` writes each sample's chat messages and stops (to send them to another endpoint). A `"mode": "super"` line runs `SuperPrompt`: the transcript is the instruction, with `"selection"` to edit or `"field"` (text before the cursor) to write into; `samples/super.jsonl` has 10 of each. Answers the app would refuse are marked REJECTED.

Live text: `lsbench live --engine <spec> [--step 0.4] [--json out.json] <audio or folder>...` transcribes the growing prefix [0, t] of each clip every 0.4 s, as a live caption (or the app's `SpeechPeekClient`) would. It prints per clip and in total: pass latency (median, p95, by prefix length), the time from speech onset to the first word and to the first word that matches the clip's `.txt` reference, how many already-shown words later passes changed (also without the last two words of each pass) and the final pass's WER. `--heads 1.0,1.7,2.5,3.3` instead prints what the engine writes for the first N seconds of each clip and what `SuperTrigger.earlyVerdict` makes of it (the "Legacy"/"Lucy" early check). Any `--engine` works, including `cohere:` and `apple`.

Apple streaming: `lsbench live --engine apple --stream [--fast] [--speed 1] [--early] [--json out.json] <audio or folder>...` feeds each clip to a `SpeechAnalyzer` as 100 ms `AnalyzerInput` buffers paced at real time (`--speed N` feeds faster, for a smoke test only: its times are not comparable) and shows finalized text plus the newest volatile result, as a live caption would. `--fast` adds `.fastResults`. It scores that caption and two "settled" ones (volatile words except the last two; only volatile words the previous update also had) with the prefix mode's columns, plus how late finalized words arrive and how far volatile text runs ahead of the finalized text; `--early` adds when `SuperTrigger.earlyVerdict` first says isSuper. Ends with `finalizeAndFinish(through:)` 10 ms before the end of the audio (at the exact end it never returns). `LSBENCH_TRACE=1` prints every result. `--confidence` also requests `.transcriptionConfidence`, writes every result's words with their confidence to the JSON and scores three-tier (solid / dim / hidden) displays; `--rescore a.json …` scores such files again without a rerun. Finding on macOS 26.6.2: volatile results carry no confidence, only final ones do.

Fillers: `lsbench fillers --engine <spec> [--out file.jsonl] <audio or folder>...` transcribes each clip and lists the fillers the Speech Coach's rules (`CoachText.analyse`) find, one JSON line per clip with `--out`. Compare engines by running it once per engine on the same folder.

Word timings: `lsbench words [--v2] <audio or folder>...` prints one JSON line per clip with Parakeet TDT's transcript and words (`{"word", "start", "end"}`, grouped as the app does), v3 unless `--v2`.

Word timing accuracy: `lsbench align --tts [--engine parakeet:v3|parakeet:phonon2|fermion:phonon2|…] <practice_lines.json> [count]` builds lines from words synthesized one at a time (exact boundaries) and reports the median start/end error and the share within 80 ms of an engine's own word timings moved onto the line's words (`WordMatcher`), with and without the app's +80 ms start shift. Without `--engine` it runs the app's method (Parakeet TDT v2).

Voiceprint check: `lsbench voice --enrol <folder> --same <folder> --other <folder>... [--embedder campplus|wespeaker] [--enrol-from-same N] [--per-file N] [--per-speaker N]` builds a voiceprint (mean CAM++ embedding, FluidAudio, downloaded into `Models/fluidaudio/campplus-coreml`; `--embedder wespeaker` uses the diarizer's WeSpeaker v2 instead) from `--enrol`, or from N of the `--same` recordings with `--enrol-from-same N` (held out of the test), cuts up to N (default 4) stretches of 1, 2 and 5 s of contiguous speech (Silero VAD) per file from `--same` (the user) and each `--other` folder (recursive; speaker = file name up to the first "-", LibriSpeech and `say` style; at most 10 files per speaker), and prints the score spread, EER and false accepts at 95%/90% of the user accepted per length, the closest other speakers and the user's lowest stretches. Whole VAD turns (first 10 s) are scored too, by length (1–2, 2–5, 5+ s). `--timeline <file>` (instead of `--same`/`--other`) prints the score of 1 s and 2 s windows every 0.5 s through a recording that mixes the user with another voice. `--diarize <file>` (with `--embedder wespeaker`) diarizes a recording of several people (FluidAudio's diarizer), scores each speaker and each turn against the voiceprint and prints a labelled transcript (`--asr`, default `parakeet:v3`).

Speech coach: `lsbench coach <audio or folder>...` runs the Coach tab's analysis (`SpeechCoach`: fillers, self-corrections, crutch words, hedges, sentence lengths, run-ons, pace, pauses, and the filler-free minute's pitch range) on each clip with Parakeet v3 and prints the summary and tips, the pause total and the clean-sentence count. `--quiet` prints only the totals; `--detail` lists every pause with its level and any words Parakeet placed in it.

`--reload` adds what the app's load-per-dictation costs: the footprint between clips, right after unloading, 5 s later, and the time to load again with warm-up.

Parakeet models download on first use into `~/Library/Application Support/LegacyScribe/Models/fluidaudio/`, the same place the app uses. Cohere checkpoints must already be on disk; fetch them with the resumable, checksum-verified downloader:

```bash
tools/fetch-hf.sh beshkenadze/cohere-transcribe-03-2026-mlx-4bit "$M/cohere-transcribe-03-2026-mlx-4bit" \
  config.json preprocessor_config.json special_tokens_map.json tokenizer.model tokenizer_config.json model.safetensors
```
