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
# Cohere audio is split into ~25 s chunks like the app; --cohere-chunk 1200 reproduces the old single-pass behaviour
lsbench --engine parakeet:v3 --fixtures "$F"        # also: parakeet:v2, parakeet:ultra, parakeet:phonon2
```

Parakeet models download on first use into `~/Library/Application Support/LegacyScribe/Models/fluidaudio/`, the same place the app uses. Cohere checkpoints must already be on disk; fetch them with the resumable, checksum-verified downloader:

```bash
tools/fetch-hf.sh beshkenadze/cohere-transcribe-03-2026-mlx-4bit "$M/cohere-transcribe-03-2026-mlx-4bit" \
  config.json preprocessor_config.json special_tokens_map.json tokenizer.model tokenizer_config.json model.safetensors
```
