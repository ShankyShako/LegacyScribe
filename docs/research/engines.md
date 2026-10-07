# STT engine facts for P1 (verified 2026-10-06)

Research drafted by OmniRoute (`delegate ask wp-search`). Each line below was checked against the macOS 26.5 SDK interface, the package source, or the Hugging Face repo. Corrections to the drafts are noted.

## Apple SpeechAnalyzer (Speech.framework, macOS 26)

- Word timings: create `SpeechTranscriber` with `attributeOptions: [.audioTimeRange]`. Each run of `result.text` carries `AttributeScopes.SpeechAttributes.TimeRangeAttribute` (a `CMTimeRange`). `rangeOfAudioTimeRangeAttributes(intersecting:)` also exists. *(SDK-verified)*
- Biasing: `AnalysisContext.contextualStrings` (keyed by `ContextualStringsTag`), applied with `SpeechAnalyzer.setContext(_:)`. *(SDK-verified)* Per an Apple forums answer, only `DictationTranscriber` honours contextual strings, not `SpeechTranscriber`. *(Not verifiable from headers: test it in P1.)*
- Files: `analyzer.analyzeSequence(from: AVAudioFile)`. Live audio: an `AsyncSequence` of `AnalyzerInput(buffer:bufferStartTime:)` passed to `start(inputSequence:)`. *(SDK-verified)*
- Assets: `AssetInventory.assetInstallationRequest(supporting: [module])?.downloadAndInstall()`. *(SDK-verified)*
- For short dictation, `DictationTranscriber` has an explicit `.punctuation` option *(SDK-verified)*. Benchmark both transcribers in `lsbench`; biasing support may decide it.

## WhisperKit (now `argmaxinc/argmax-oss-swift`, MIT)

- Latest tag **v1.1.0** (the draft said v1.0.0). Use ≥1.1.0: it fixes `promptTokens` producing empty transcripts. Products: `WhisperKit`, plus the umbrella `ArgmaxOSS`.
- `DecodingOptions.wordTimestamps: Bool` → `TranscriptionResult.segments[].words: [WordTiming]` with `word`, `tokens`, `start: Float`, `end: Float`, `probability` (the draft wrongly said `Double`).
- `DecodingOptions.promptTokens: [Int]?`, from `tokenizer.encode(text:)`. Capped at `Constants.maxTokenContext / 2 - 1` tokens (≈223) in `TextDecoder.swift`. Known caveat: prompt text can leak into output.
- Large v3 Turbo folders in `argmaxinc/whisperkit-coreml`: `openai_whisper-large-v3_turbo`, `…_turbo_954MB`, `openai_whisper-large-v3-v20240930_turbo`, `…_turbo_632MB`.

## Cohere Transcribe 03-2026

- No timestamps, no free-text prompt (model card). Swift: `CohereTranscribeModel.fromDirectory(_:)` in mlx-audio-swift loads quantized MLX checkpoints. FluidAudio's CoreML port runs at ~2× real time, too slow for dictation.

## Parakeet TDT (FluidAudio ≥0.17.5)

- Variants: `v2` (English), `v3`, `ultra` (more accurate v3 retrain), `phonon2` (English, fastest ANE encoder), `redux` (smaller). `ASRResult.tokenTimings` gives timings. Vocabulary boosting runs through the CTC keyword spotter (`Documentation/ASR/CustomVocabulary.md`).
- FluidAudio ≥0.17 links a Rust xcframework (`NemoTextProcessing`). Never link the app with `-interposable` (see CLAUDE.md).
