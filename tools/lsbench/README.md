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
```

Notes speech gate: `lsbench vad [--engine cohere:<dir>] <wav or folder>...` prints what Silero VAD, with the app's notes settings, keeps of each clip. With `--engine`, each clip is also transcribed whole and gated, to compare what silence or noise turns into.

On-device rewrite: `lsbench rewrite --model <mlx-dir> --samples <file.jsonl> [--json out.json] [--no-think]` runs the app's rewrite prompts through an MLX model. Each sample line is `{"mode": "clean"|"prompt", "transcript": "…", "reference": "…"}`. Pass `--no-think` for Qwen3's hybrid models (1.7B, 8B). `samples/self-correction.jsonl` checks the self-correction rule (Clean corrections, lookalikes, Prompt corrections). A `"mode": "s1"` line runs S1-mini's fixed normalizer prompt (optional `"control"` line, greedy; pass `--no-think`). A `"mode": "chat"` line sends its `"system"` text and the transcript (for fine-tuned models). "s1" and "chat" answers are capped at 2.5 × the heard words + 64 tokens and retried once with repetition penalty 1.1 if they hit it. `"append"` adds text to a clean/prompt sample's system message, and `--messages out.jsonl` writes each sample's chat messages and stops (to send them to another endpoint). A `"mode": "super"` line runs `SuperPrompt`: the transcript is the instruction, with `"selection"` to edit or `"field"` (text before the cursor) to write into; `samples/super.jsonl` has 10 of each. Answers the app would refuse are marked REJECTED.

Word timings: `lsbench words [--v2] <audio or folder>...` prints one JSON line per clip with Parakeet TDT's transcript and words (`{"word", "start", "end"}`, grouped as the app does), v3 unless `--v2`.

Voiceprint check: `lsbench voice --enrol <folder> --same <folder> --other <folder>... [--embedder campplus|wespeaker] [--enrol-from-same N] [--per-file N] [--per-speaker N]` builds a voiceprint (mean CAM++ embedding, FluidAudio, downloaded into `Models/fluidaudio/campplus-coreml`; `--embedder wespeaker` uses the diarizer's WeSpeaker v2 instead) from `--enrol`, or from N of the `--same` recordings with `--enrol-from-same N` (held out of the test), cuts up to N (default 4) stretches of 1, 2 and 5 s of contiguous speech (Silero VAD) per file from `--same` (the user) and each `--other` folder (recursive; speaker = file name up to the first "-", LibriSpeech and `say` style; at most 10 files per speaker), and prints the score spread, EER and false accepts at 95%/90% of the user accepted per length, the closest other speakers and the user's lowest stretches. Whole VAD turns (first 10 s) are scored too, by length (1–2, 2–5, 5+ s). `--timeline <file>` (instead of `--same`/`--other`) prints the score of 1 s and 2 s windows every 0.5 s through a recording that mixes the user with another voice. `--diarize <file>` (with `--embedder wespeaker`) diarizes a recording of several people (FluidAudio's diarizer), scores each speaker and each turn against the voiceprint and prints a labelled transcript (`--asr`, default `parakeet:v3`).

Speech coach: `lsbench coach <audio or folder>...` runs the Coach tab's analysis (`SpeechCoach`: fillers, self-corrections, crutch words, hedges, sentence lengths, run-ons, pace, pauses, and the filler-free minute's pitch range) on each clip with Parakeet v3 and prints the summary and tips, the pause total and the clean-sentence count. `--quiet` prints only the totals; `--detail` lists every pause with its level and any words Parakeet placed in it.

`--reload` adds what the app's load-per-dictation costs: the footprint between clips, right after unloading, 5 s later, and the time to load again with warm-up.

Parakeet models download on first use into `~/Library/Application Support/LegacyScribe/Models/fluidaudio/`, the same place the app uses. Cohere checkpoints must already be on disk; fetch them with the resumable, checksum-verified downloader:

```bash
tools/fetch-hf.sh beshkenadze/cohere-transcribe-03-2026-mlx-4bit "$M/cohere-transcribe-03-2026-mlx-4bit" \
  config.json preprocessor_config.json special_tokens_map.json tokenizer.model tokenizer_config.json model.safetensors
```
