# LegacyScribe

Local-first dictation for macOS. Hold **Right ⌥**, speak, and release; the transcript is pasted into whatever app is focused. Double-tap Right ⌥ to lock recording on, tap again to stop. Press Esc to cancel.

Speech-to-text runs on-device (Parakeet via FluidAudio and Whisper via WhisperKit today; Cohere Transcribe and Apple SpeechAnalyzer next). LLM cleanup with on-device or cloud models arrives in Phase 2. See [`docs/plan.md`](docs/plan.md) for the roadmap.

Forked from [Hex](https://github.com/kitlangton/Hex) by Kit Langton (MIT). See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Requirements

Apple Silicon Mac, macOS 26 or later, Xcode 26.

## Build and run

```bash
open Hex.xcodeproj        # scheme "Hex" builds "LegacyScribe Debug.app"
```

On first launch, grant Microphone, Accessibility and Input Monitoring in System Settings → Privacy & Security. Keep the same signing team between builds so macOS remembers the grants.

Data (history, audio, models) lives in `~/Library/Application Support/LegacyScribe/`.

## Benchmarks

`tools/lsbench` measures STT latency, memory and word error rate on audio clips. See [`tools/lsbench/README.md`](tools/lsbench/README.md).

## License

MIT
