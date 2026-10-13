# Third-party notices

LegacyScribe is MIT-licensed. It is a fork of, or depends on, the projects below. Check a
project's license before vendoring code from it, and add it here when you do.

| Project | Use | License |
|---|---|---|
| [Hex](https://github.com/kitlangton/Hex) | Forked app base (hotkeys, recording, paste, history, model UI) | MIT |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Parakeet ASR, VAD, CTC keyword spotting (SwiftPM) | Apache-2.0 |
| [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) | Whisper ASR (SwiftPM) | MIT |
| [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) | Cohere Transcribe on MLX (SwiftPM) | MIT |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) and [mlx-swift](https://github.com/ml-explore/mlx-swift) | On-device rewrite and notes model (SwiftPM) | MIT |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | Tokenizers for the on-device model (SwiftPM) | Apache-2.0 |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite store for history, word timings and corrections (SwiftPM) | MIT |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | App updates (SwiftPM) | MIT |
| [swift-composable-architecture](https://github.com/pointfreeco/swift-composable-architecture) and Point-Free libraries | App architecture (SwiftPM) | MIT |
| [Sauce](https://github.com/Clipy/Sauce) | Keyboard layout handling (SwiftPM) | MIT |

Reference implementations we plan to port code from, with attribution in the ported files:

| Project | What | License |
|---|---|---|
| [FreeFlow](https://github.com/zachlatta/freeflow) | Accessibility context capture, Keychain storage, cleanup prompt (P2–P3) | MIT |

Models (downloaded at runtime, not redistributed):

| Model | License |
|---|---|
| [Cohere Transcribe 03-2026](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026) (MLX conversions by `beshkenadze`) | Apache-2.0 |
| [Parakeet TDT](https://huggingface.co/FluidInference) (CoreML conversions by FluidInference) | CC-BY-4.0 |
| [Qwen3 1.7B / 4B-Instruct-2507 / 8B](https://huggingface.co/Qwen) (4-bit MLX conversions by `mlx-community`) | Apache-2.0 |
| [Silero VAD](https://github.com/snakers4/silero-vad) (CoreML conversion by FluidInference) | MIT |

GPL-3.0 projects (VoiceInk, FluidVoice) were reviewed and **not** used; their code must not be copied here.
