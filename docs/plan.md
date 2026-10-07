# LegacyScribe — Architecture & Phased Plan

## Context
A personal, MIT-licensed menu-bar dictation app for macOS (Superwhisper-style): hotkey → speak → cleaned text pasted into the focused app. Local-first, with optional cloud LLMs through OmniRoute. Built on an M5 with 24 GB RAM, macOS 26.6.2, Xcode 26.5, Swift 6.3.2.

### Decisions locked
| Topic | Decision |
|---|---|
| Name / license | LegacyScribe, MIT, personal tool |
| Platform | **macOS 26+ on Apple Silicon only.** SpeechAnalyzer needs macOS 26. Model defaults are tiered by RAM, so 8–16 GB M-series Macs still work. |
| Language | English only. Pass `language: en` explicitly everywhere. |
| Data | `~/Library/Application Support/LegacyScribe/` holds `scribe.sqlite`, `audio/YYYY/MM/<uuid>.flac`, `calibration/`, `corrections/` and `Models/`. Models are flagged `isExcludedFromBackup`. **Nothing goes inside the Syncthing-synced Homework folder except the source repo.** |
| Retention | Raw audio is deleted after 30 days. Text history is kept forever. Correction pairs and calibration audio are kept forever and pinned. All of this is configurable. |
| Hotkeys | Hold **Right ⌥** = push-to-talk. **Double-tap Right ⌥** = toggle. **Esc** = cancel. **⌃⌥1–4** = Raw / Clean / Super / Private. All rebindable. |
| Private-mode LLM | In-process **mlx-swift-lm** running a downloaded small instruct model. Zero sockets. |
| OmniRoute | `http://localhost:20128/v1` with an API key stored in Keychain. Model lists come from `/v1/models` and are chosen per mode. |

## Research findings that change the brief
1. **Cohere Transcribe has no timestamps and no free-text prompting.** The model card says timestamps aren't supported. The decoder prompt is only control tokens (language and punctuation). The consequences:
   - Cohere's word timings must come from a separate **CTC forced aligner**.
   - Cohere's biasing must be **LLM-side only**.
   - Injecting a decoder prefix is an untrained hack. It's an optional experiment, not a feature.
2. **Swift runtimes for Cohere already exist.**
   - `Blaizzy/mlx-audio-swift` (MIT) has `MLXAudioSTT/Models/CohereTranscribe`. It's documented with an fp16 checkpoint only. 4-bit (`mlx-community` 8-bit, a community 4-bit) needs to be verified.
   - FluidAudio (Apache-2.0) has a CoreML `CoherePipeline`, but it benchmarks at only about 2× real time on M2/M4. Too slow for dictation.
   - Dictum (MIT, Python MLX) reports about 0.25 s for a 9 s clip at 4-bit. **MLX is the path.**
3. **What each engine offers:**

   | Engine | Word timestamps | ASR biasing hook |
   |---|---|---|
   | Parakeet TDT v3 (FluidAudio) | token timings | vocabulary boosting (CTC keyword-spotter rescoring), not a prompt |
   | WhisperKit (now `argmaxinc/argmax-oss-swift`, MIT) | yes (`wordTimestamps`) | `promptTokens` |
   | SpeechAnalyzer | `audioTimeRange` attributes | `AnalysisContext.contextualStrings` (verify) |
   | Cohere | none | none |

   Also cheap to add since we're English-only: **Parakeet TDT v2** (English-only, slightly better English WER).
4. **Fork licenses:**
   - VoiceInk is GPL-3.0 and FluidVoice is GPL-3.0, so both are excluded.
   - MIT candidates: Hex, FreeFlow, OpenSuperWhisper.

## Fork decision: fork **Hex** (kitlangton/Hex, MIT), borrow from **FreeFlow** (MIT)
- **Hex** already has the following, which is the biggest head-start:
  - FluidAudio Parakeet v3 and WhisperKit (2 of our 4 engines)
  - Hold and double-tap hotkey logic (`HexCore/Logic/HotKeyProcessor.swift`)
  - `PasteboardClient` with clipboard restore
  - A history feature and a model-download UI
  - A testable `HexCore` SPM package
  - TCA dependency "Clients", which are good seams for pluggable engines and providers

  The upstream Swift repo is now marked "legacy" (the author moved to Rust). We fork hard and own it.
- **FreeFlow** (cloud-first; its 3.4k-line `AppState` makes it a poor base) is the reference for:
  - `AppContextService.swift` (AX focused-app and selection capture)
  - `KeychainStorage.swift`, `LLMAPITransport.swift`
  - The pasteboard preservation in `AppState.swift` (`PreservedPasteboardItem`)
  - Its cleanup prompt

  Port with attribution in `THIRD_PARTY_NOTICES.md`.
- OpenSuperWhisper is whisper.cpp-centric and a weaker fit.

## Architecture
The repo lives at `~/Documents/Homework/AI/LegacyScribe`. It's an Xcode app plus local SPM packages, following Hex's `HexCore` pattern.

```
LegacyScribe.app (SwiftUI + TCA, unsandboxed, stable signing identity so TCC grants survive rebuilds)
 ├─ Features: Dictation, History(+edit), Settings(Providers/Keys, Modes, Vocabulary), Calibration
 ├─ ScribeCore      – models, settings, Mode + auto-activation rules, hotkey logic, PromptBuilder,
 │                    BiasingContext builder, text normalizer, WER (pure Swift, unit-tested)
 ├─ STTKit          – protocol SpeechEngine + adapters: Parakeet(FluidAudio), Cohere(mlx-audio-swift),
 │                    Whisper(argmax-oss-swift), SpeechAnalyzer; WordAligner (CTC forced alignment)
 ├─ LLMKit          – LLMProvider registry; one OpenAI-compatible client (OmniRoute, OpenAI, Gemini
 │                    compat, Anthropic compat or native, Ollama, custom); MLXLocalProvider (mlx-swift-lm);
 │                    NetworkPolicy gate
 ├─ ContextKit      – AX capture (focused app/bundle ID, field text, selection, recent-clipboard ≤3s)
 ├─ OutputKit       – paste: transient/concealed pasteboard types, ⌘V via CGEvent, restore, secure-input check
 ├─ Store           – GRDB SQLite (dictations, words, corrections, calibration runs) + retention job
 ├─ lsbench (CLI)   – runs any engine/LLM on fixture WAVs → latency + WER JSON (P0 onward)
 └─ tools/ (Python, uv) – offline eval + LoRA fine-tune; never in the hot path
```

**Core protocol (sketch):**
```swift
protocol SpeechEngine: Sendable {
  var id: EngineID { get }
  var capabilities: EngineCapabilities { get }   // .wordTimestamps, .promptBiasing, .vocabBoost, .streaming
  func prepare() async throws                     // load + warm (keep resident)
  func transcribe(_ audio: PCM16kMono, options: TranscribeOptions) async throws -> Transcript
}
// TranscribeOptions.biasing: BiasingContext? — each adapter maps it to promptTokens / vocab boost /
// contextualStrings or ignores it; if ignored, the pipeline routes the vocabulary to the LLM prompt instead.
// Transcript.words == nil → pipeline runs WordAligner when timestamps are needed (history, calibration).
```

**Pipeline:**

hotkey down → AVAudioEngine capture (16 kHz mono ring buffer) and, in parallel, a ContextKit snapshot (taken at key-down, before focus can change) → hotkey up → VAD trim (Silero via FluidAudio) → `SpeechEngine` → mode's LLM step (or none for Raw) → OutputKit paste → Store write.

Each stage is timed with `os_signpost` so latency is visible in Instruments and in the history view.

**Private-mode enforcement:**
- All HTTP goes through one `HTTPTransport` that asks `NetworkPolicy`.
- In Private mode the policy denies every request, and a custom `URLProtocol` is registered on every app `URLSessionConfiguration` as a backstop.
- Model loaders take local paths only; lazy auto-download is disabled while Private is active.
- A unit test asserts zero transport calls for a Private dictation.
- A manual check uses `nettop -p <pid>` (see Verification).

## Phases (revised)
I made two changes to your proposed sequence:
- **Correction capture moves to P1**, so pairs accumulate for weeks before P5 needs them.
- **P0 de-risks Cohere in a CLI harness** before any app wiring.

**P0: Fork + spike (decision gate)**
1. Fork Hex, rebrand to LegacyScribe, and get it building on Xcode 26.5 / Swift 6.3. Bump FluidAudio and move WhisperKit to argmax-oss-swift. Set up a stable dev signing identity.
2. Rebind to Right ⌥ hold / double-tap. Check that left and right modifiers are distinguished correctly.
3. Add signposts and an in-app "last dictation latency" readout, measured from key-up to paste. Use Parakeet v3.
4. Build `lsbench` and run Cohere through mlx-audio-swift with the fp16, 8-bit and 4-bit variants:
   - Report cold load, warm latency for 3 s / 10 s / 30 s clips, peak RSS, and WER on about 20 self-recorded fixtures.
   - If Swift 4-bit fails, quantize with Python `mlx-audio` and load the result in Swift.
5. Run the paste-reliability matrix (below).
6. Write `CLAUDE.md` (architecture decisions so far) and `THIRD_PARTY_NOTICES.md`.

**Exit criterion:** We decide the default engine from the numbers. The target is a warm 10 s clip transcribed in under 500 ms.

**P1: Engines + history + correction capture**
1. Extract `SpeechEngine` from Hex's `TranscriptionClient`/`ParakeetClient` and add adapters for Cohere, WhisperKit, SpeechAnalyzer and Parakeet v2.
2. Build `WordAligner`, a CTC Viterbi alignment of text to audio using FluidAudio's Parakeet CTC-110M (`CtcDPAlgorithm` exists).
3. Add GRDB Store, the audio retention job, and history with playback.
4. **Editable history.** Each history entry has two editable fields:
   - **verbatim** (what I actually said), which becomes the ASR training target
   - **final** (the LLM output)

   Editing either one saves a correction pair (audio, raw ASR, LLM output, corrected verbatim, corrected final). This split matters because LLM-cleaned text isn't valid ASR ground truth: fillers have been removed.

**P2: LLM layer + modes + Private**
- Provider registry with Keychain storage (`kSecClassGenericPassword`, service `LegacyScribe.provider.<id>`), plus a Settings "Test" button that runs `/v1/models` and a 1-token completion.
- OmniRoute as the default provider.
- `MLXLocalProvider` with a model picker. Before choosing the default, I'll run a small eval in `lsbench`: cleanup quality and latency on 30 transcripts across about 3 candidate 3–4B 4-bit instruct models. **Avoid CC-BY-NC weights** (e.g. Tiny Aya) as the shipped default.
- The Mode model (engine + provider/model + prompt + hotkey + per-bundle-ID auto-activation rules), with the four built-in modes, `NetworkPolicy`, and per-mode routing.

**P3: Context + Super + biasing**
1. Add ContextKit:
   - Electron and Chrome need `AXManualAccessibility` / `AXEnhancedUserInterface` set on the target app.
   - Truncate field text around the cursor.
   - Skip password fields and secure input.
2. Add the vocabulary list UI and the `BiasingContext` builder (vocabulary + proper nouns from the focused text + recent corrections, capped by each engine's token budget).
3. Wire biasing into each engine's hook, with LLM-side fallback.
4. Write the Super prompt.

**P4: Calibration + WER**
- Generate 30–50 sentences from the vocabulary with an LLM.
- Read-along UI with karaoke highlighting from word timings (native timings, or the aligner for Cohere).
- Normalized WER per engine (Whisper-style English normalizer), plus an auto-recommendation.
- Stretch goal: live highlighting by streaming CTC alignment against the known script.

**P4.5: Fine-tune feasibility spike.** This is new and runs before P5. Find out which engine is realistically LoRA-tunable on-device:
- Cohere: the MLX Python model definition exists, so a training loop is plausible.
- Whisper: possible through MLX/PEFT.
- Parakeet: CoreML export makes it hard.

The spike also has to establish the minimum hours of pairs needed and confirm the tuned weights load in the Swift runtime.

**P5: LoRA pipeline**
- A background `tools/finetune` job (uv + MLX) that trains on the verbatim pairs and re-scores on the calibration set plus a held-out set of pairs.
- It swaps in the adapter only if WER improves by more than a set margin.
- Every promotion is recorded as a versioned model entry in Store, with rollback.

## Riskiest assumptions → how we verify
| # | Assumption | Verify | When / fallback |
|---|---|---|---|
| 1 | Cohere 4-bit runs in-process in Swift at < 500 ms for a warm 10 s clip on the M5 | `lsbench` numbers | P0. Fallback: 8-bit or fp16, or Parakeet as the default |
| 2 | 4-bit doesn't hurt WER on my voice | `lsbench` WER across quantizations on my fixtures | P0 |
| 3 | The CTC aligner gives usable word timings (±80 ms) for Cohere | Compare against Parakeet/Whisper timings on the same clips | P1 |
| 4 | ⌘V paste works everywhere | Matrix: VS Code, Cursor, Slack, Discord (Electron); Safari, Chrome, Arc; Terminal, iTerm2, Ghostty; Xcode, Notes, Messages; a password field (must refuse). Check the restored clipboard and that clipboard managers ignore the transient item | P0; re-run each phase |
| 5 | AX gives field text in Electron and Chrome | Context-dump debug panel per app | P3 |
| 6 | Hex builds cleanly on Swift 6.3 with current FluidAudio and argmax-oss-swift | P0 step 1 | P0. Fallback: start from scratch, porting Hex modules |
| 7 | TCC (Accessibility, Input Monitoring, Mic) grants survive rebuilds | Stable signing identity; rebuild twice and confirm no re-prompt | P0 |
| 8 | Private mode truly makes no network calls | Unit test plus `nettop -p $(pgrep LegacyScribe)` during Private dictations | P2 |
| 9 | Some engine is LoRA-tunable and loadable back into Swift | P4.5 spike | Before P5 is committed |
| 10 | Memory fits: Cohere-4bit (~1.6 GB) + local LLM (~2.5 GB) + Parakeet, all resident | `lsbench` peak RSS; unload idle engines | P2 |

## Verification (how you test each phase)
- **P0:**
  - `xcodebuild -scheme LegacyScribe build` succeeds.
  - Hold Right ⌥, speak 10 s in Notes, and text appears. The latency readout shows key-up → paste time.
  - `swift run -c release lsbench --engine cohere-mlx-4bit --fixtures fixtures/` prints JSON with latency, RSS and WER.
  - Fill in the paste matrix checklist in `docs/paste-matrix.md`.
- **P1:**
  - Switching engines in Settings changes the output.
  - History shows audio playback with word highlighting.
  - Editing an entry creates a row in the `corrections` table (check with `sqlite3`).
- **P2:**
  - The Settings "Test" button goes green for OmniRoute.
  - ⌃⌥1–4 switches modes.
  - With Private active, `nettop` shows no new sockets, and with Wi-Fi off it still works.
- **P3:**
  - Dictating a name that appears in the focused document gets it spelled right.
  - The debug panel shows captured context per app.
- **P4:**
  - Complete a calibration run. A per-engine WER table and a recommendation appear.
- **P5:**
  - A dry run on synthetic pairs produces an adapter, a re-score report, and no swap when WER doesn't improve.
