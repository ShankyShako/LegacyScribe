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
| Retention | Raw audio is deleted after 30 days. Text history is kept forever. Correction pairs and calibration audio are kept forever and pinned. All of this is configurable. *Built 2026-10-12 for dictation audio (Settings > History > Keep Recordings); recordings behind an edited sent text are pinned.* |
| Hotkeys | Hold **Right ⌥** = push-to-talk. **Double-tap Right ⌥** = toggle. **Esc** = cancel. **⌃⌥1–4** = Raw / Clean / Prompt / Notes (Super became a spoken prefix, P3.5 B1; Private is a toggle). All rebindable. |
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

*Status (2026-10-12).* Built: the `SpeechEngine` protocol with Parakeet (v2 and v3), Cohere and a new Apple SpeechAnalyzer engine (WhisperKit stays inline as the fallback); the GRDB store (`scribe.sqlite`: dictations, words, corrections) behind the existing `@Shared` keys, importing the JSON files once; audio retention; history playback that highlights each word as it plays. Changed: word timings come from Parakeet TDT's own timings moved onto the transcript's words, not a CTC aligner (measured: CTC 110M ~600 ms off, TDT ~50 ms; see `docs/bench-results.md`). Dropped: editable history (item 4), superseded by sent-text capture. Not done: the split into separate packages and the rename that goes with it; HexCore is still the one package.

**P2: LLM layer + modes + Private**
- Provider registry with Keychain storage (`kSecClassGenericPassword`, service `LegacyScribe.provider.<id>`), plus a Settings "Test" button that runs `/v1/models` and a 1-token completion.
- OmniRoute as the default provider.
- `MLXLocalProvider` with a model picker. Before choosing the default, I'll run a small eval in `lsbench`: cleanup quality and latency on 30 transcripts across about 3 candidate 3–4B 4-bit instruct models. **Avoid CC-BY-NC weights** (e.g. Tiny Aya) as the shipped default.
- The Mode model (engine + provider/model + prompt + hotkey + per-bundle-ID auto-activation rules), with the four built-in modes, `NetworkPolicy`, and per-mode routing.

*Pulled ahead (2026-10-10), so that anyone can set the app up:* provider presets with plain API keys (OpenAI, Anthropic, Gemini, Groq, OpenRouter, plus Ollama and any OpenAI-compatible server), and the in-process MLX model (Qwen3 1.7B / 4B / 8B, downloaded from Settings). This is enough of `MLXLocalProvider` for rewriting and notes. *Built 2026-10-12:* `NetworkPolicy` and Private mode (a setting and menu bar toggle rather than ⌃⌥4, which went to Notes): on-device rewrite only, no update checks, every request in the process refused by a `URLProtocol` swizzled into all `URLSession` configurations, and `PrivateModeTests`, a real on-device dictation with the process's sockets sampled every 10 ms. Still open from P2: the full Mode model (engine + provider + prompt + hotkey + per-app rules). See CLAUDE.md "Providers" and "On-device rewrite", and `docs/bench-results.md` for the 4B numbers.

**P3: Context + Super + biasing**
1. Add ContextKit:
   - Electron and Chrome need `AXManualAccessibility` / `AXEnhancedUserInterface` set on the target app.
   - Truncate field text around the cursor.
   - Skip password fields and secure input.
2. Add the vocabulary list UI and the `BiasingContext` builder (vocabulary + proper nouns from the focused text + recent corrections, capped by each engine's token budget).
3. Wire biasing into each engine's hook, with LLM-side fallback.
4. Write the Super prompt.

*Status (2026-10-12, in progress).* Built: `BiasingContext` in HexCore (`Context/BiasingContext.swift`, `BiasingContextTests`): the vocabulary, spellings the user fixed in sent text (`CorrectionTerms`: similar-looking replaced spans; a plain lowercase fix counts only after two edits, since "makes" → "takes" looks just like "equitable" → "equatable"), and names near the cursor (`ContextTerms`: ±3,000 characters, CamelCase, acronyms, words with digits or dots, handles, slash commands, capitalized words that don't start a sentence, adjacent ones joined into one name). The focused field and cursor are read at key-down (`FocusedText.cursor`, setting `contextTermsEnabled`), the context is built at key-up, and the rewrite gets the vocabulary + fixes as exact spellings and the nearby names as a separate hint (only the names leave the Mac, not the text). Next: measure Parakeet's CTC vocabulary rescoring and Apple's `contextualStrings` in `lsbench` (the 10 recorded practice lines with jargon, plus `fixtures/me` for false replacements) before wiring either into the engine; WhisperKit `promptTokens`. Super is redesigned in P3.5 B1; P3.5 part A and A7 come first.

**P3.5: Adopted from competitors (planned 2026-10-12).** Comparison and sources: `docs/research/competitors.md`. Most of what Wispr Flow, Superwhisper and VoiceInk sell is already here; these are the gaps worth closing. Part A is small, independent work that helps every dictation. **Order (decided 2026-10-12):** part A and A7 first, then P3's `lsbench vocab` (engine biasing mostly helps Parakeet users, and the user dictates on Cohere), then part B. **Changed 2026-10-12, after part A shipped:** B1 (Super) comes next, ahead of `lsbench vocab`; the user tried "super" live and wants it now. B1 built the same day; next is `lsbench vocab`. **Changed 2026-10-13:** P3.6 (hackathon round) comes first. Part B is decided but built later, each feature behind its own setting. Each item gets a CLAUDE.md row when built.

*A1. Self-correction ("backtrack"; Wispr, Willow).* "Meet at 2, no, make it 3" should come out as "Meet at 3." *Built 2026-10-12:* a rule in the always-appended system rules (so custom instructions get it too) plus one line in Prompt's task; Clean 5/5 on the 4B and qwen3:8b, Prompt 3/3 once the transcript is punctuated as engines write it. See `docs/bench-results.md` "Self-correction rule"; gpt-oss-120b not yet checked.
- Add a rule to the Clean and Prompt default instructions (`RewritePromptBuilder.swift`): when the speaker corrects themselves ("no, make it…", "scratch that", "I mean…", "actually…" followed by a replacement), keep only the corrected version. A "no" that is an answer ("No, I don't think so") stays. Defaults reach everyone who hasn't edited their instructions.
- Verify: a `RewriteTests` case for the prompt text. Run `lsbench rewrite` on ~8 dictations, half self-corrections and half lookalikes ("no" as an answer, "I mean it", "actually" as an adverb), on the on-device 4B and gpt-oss-120b. Every correction should be resolved and no lookalike dropped. Record the results in `docs/bench-results.md`.

*A2. Match the surrounding text on paste (Superwhisper 2.8 "smart capitalization").* *Built 2026-10-12* (`InsertionAdjuster` in `Models/`, 13 unit tests, 2 pipeline tests); confirmed live in T3 Code and TextEdit. Changes from the plan: the field is read just before the paste (the read sent-text capture already makes) rather than at key-down, so the cursor is where the paste lands, and a selection is skipped over since the paste replaces it. Names the Natural Language tagger recognises, weekdays and months keep their capital too ("March"/"May" left out as common words). A multi-line answer only gets spacing.
- Pure function in HexCore (e.g. `Formatting/InsertionAdjuster.swift`) taking the text, the characters before the cursor and the characters after it:
  - Lowercase the first letter when the text before the cursor doesn't end a sentence (not empty, `.`, `!`, `?`, `:` or a newline). Leave the first word alone when it is "I"/"I'm"/…, an acronym, has inner capitals, or is in the vocabulary, corrections or nearby terms.
  - Drop the final period when the text after the cursor continues the sentence (starts with a letter or a comma).
  - Add a leading space after a word or punctuation, and a trailing space before a word.
- Input: the `state.fieldContext` already read at key-down (`FocusedText.value`/`.cursor`). No cursor or no field means no change. Skip terminals, field merges (the field is replaced whole) and leading slash commands.
- The adjusted text is what gets pasted and stored as the pending sent edit (`TranscriptionFeature.swift` ~1126/1180), so sent-text capture still finds it. History keeps the unadjusted text.
- Setting `matchSurroundingText` (default on), toggle in Settings > General.
- Verify: HexCore unit tests for each rule and each exception. Live: dictate into the middle of a sentence in TextEdit, Notes, Slack and a browser textarea.

*A3. Keep failed dictations (Wispr, May 2026).* *Built 2026-10-12;* not yet tried live. A failure during speech-to-text sends `transcriptionFailed` (a failed save or paste still discards as before); the entry is kept with `failure` (GRDB migration `v2`), a "Transcription failed: kept in History" pill shows for 4 s, and copy-last-transcript skips failed entries. Retry uses the current mode with the vocabulary and fixed spellings but no code talk, merge or nearby names. The word fixes and rewrite chain moved into `TranscriptRewriter` (`redo`), which A4 reuses.
- `handleTranscriptionError` (`TranscriptionFeature.swift` ~1052) currently deletes the audio. Instead, move it to `Recordings/` the way a success does and add a history entry with empty text and a new `failure: String?` on `Transcript`, with a GRDB migration adding the column to `dictations`.
- History shows "Transcription failed" with **Retry**. Retry runs the current engine and the rewrite, then copies the result (no paste: the user has moved on) and updates the entry.
- Esc-cancel still discards, and a recording too short to transcribe isn't kept. Failed entries follow the normal 30-day audio sweep.
- Verify: a TCA test with a throwing transcription client (entry kept, audio moved, retry fills it). A `ScribeStore` migration test on an existing database.

*A4. Redo from history (Superwhisper 2.8).* *Built 2026-10-12* (`HistoryRedoTests`, 4); not yet tried live. Rewrite again offers Clean and Prompt; a failed one leaves the entry and shows why under it. Replace takes the other engine's words as recognized (no rewrite) and clears the stored word timings so playback places the new words. A context menu on each entry:
- **Rewrite again as Clean / Prompt / …** runs `RewriteChain` on `rawText ?? text` with the current endpoints, vocabulary and corrections (the field context is gone). It replaces `text`, keeps `rawText` and sets `rewriteMode`/`rewrittenBy`.
- **Transcribe again with <engine>** (only while the audio exists, not `audioRemoved`) runs `TranscriptionClient.transcribe` with the chosen downloaded model. The result is shown under the entry with Replace / Copy, and the engine name is logged. This doubles as a real-speech engine comparison for P4.
- Neither pastes. Both copy on request.
- Verify: TCA tests for both actions, including the audio-gone case.

*A5. Paste the original (Wispr "Undo AI edit").* *Built 2026-10-12:* "Copy original" next to "Show original" and in the context menu. A **Copy original** button next to "Show original" in History (`HistoryFeature.swift` ~303). A hotkey that swaps the text it just pasted is B4.

*A6. URL scheme (Superwhisper 2.16.3).* *Built 2026-10-12* (`URLAction` in HexCore with 4 parser tests, `URLActionTests` reducer tests, scheme from the `URL_SCHEME` build setting, toggle "Let links start recording" in Settings > General). `stop` and `toggle` end whichever is recording, a dictation or a notes session. Confirmed live: toggle, start, cancel, mode.
- `legacyscribe://` for Release and `legacyscribe-debug://` for Debug, set through an Info.plist build setting so the two apps don't fight over the scheme.
- Actions: `start`, `stop`, `toggle`, `cancel`, `mode/<raw|clean|prompt|notes>`, `notes/start`, `notes/stop`. They're handled in `HexAppDelegate` (`application(_:open:)`), which forwards them to the existing TranscriptionFeature actions the hotkey uses.
- Any web page can open a custom URL (the browser asks first), so a URL could start the microphone. Setting `urlActionsEnabled` defaults to off; when off, only `stop`, `cancel` and `mode/…` work.
- Verify: `open "legacyscribe-debug://toggle"` starts and stops a dictation. A reducer test for the URL parser.

*A7. Retention: a 14-day option and smaller files.* *Built 2026-10-12;* not yet tried live. Measured on 92 s of the user's calibration recordings: 32-bit float WAV 3.84 MB/min, 16-bit FLAC 1.05 MB/min (3.7× smaller), sample-exact on 16-bit audio, and `AVAudioPlayer` plays it. `RecordingCompression.flac` (HexCore) writes `<name>.partial.flac`, checks the frame count and renames; `AudioRetentionSweep.compress` repoints the entry before deleting the WAV, runs after every saved dictation (detached, utility priority) and at the start of each sweep, also with "Forever". Settings shows "Recordings use …".
- Add "14 days" to Settings > History > Keep Recordings (`HistorySectionView.swift` ~62; it has 7 / 30 / 90 / 365 / Forever). The default stays 30.
- Dictation audio is saved as 32-bit float WAV at 16 kHz (`SuperFastCaptureController.swift` ~324), about 3.8 MB a minute. When a recording is moved to `Recordings/` after the paste, off the hot path, convert it to FLAC (lossless, so it stays fine-tuning data; estimated ~1 MB a minute; measure). History playback, word timings and redo-from-history read FLAC through `AVAudioFile`. Existing WAVs are converted once by the retention sweep. Calibration audio is already 16-bit and stays WAV (lsbench fixtures).
- Show the space used next to the picker ("Recordings use 1.2 GB").
- Estimate: 1 h/day of dictation kept 30 days is ~6.9 GB now, ~1.8 GB as FLAC and ~0.85 GB at 14 days.
- Verify: unit test on the conversion (sample-exact round trip). Playback and word timings work on a FLAC entry. The sweep converts old WAVs and still honours pins.

*B. Decided 2026-10-12, built after part A, A7 and P3's `lsbench vocab`. Every feature here gets its own setting.*
- **B1. Super: say "super" first** (Wispr Transforms/Command Mode, Superwhisper Super mode). This replaces the planned ⌃⌥3 Super mode (⌃⌥3 is Prompt, ⌃⌥4 Notes). There is no Super entry in the ⌃⌥ cycler: it lasts one dictation.
  - *Renamed 2026-10-12 at the user's request: the spoken word is "Legacy" or "Lucy" (the app's name and its nickname); the pill says "Legacy". Code identifiers still say Super.* The first live try did nothing because the user was running an older Release build; rebuilt and relaunched.
  - *Built 2026-10-12, not yet tried live.* `SuperTrigger` (trigger + early verdict) and `SuperPrompt` (edit/write messages, length check) in HexCore, 37 test cases; `RewriteChain.run(messages:…)` shared with the rewrite; `TranscriptionFeature.handleSuper`, `SpeechPeekClient`, `recordingHead` on the capture controller, `SuperRim` on the capsule; `SuperPipelineTests` (10). The 4B passed 18/20 samples at 0.4–0.9 s (bench-results), so Settings has no warning. Differences from the plan: "Super!" and "supermode" also trigger; "super" alone shows "Say what to do after 'super'" and does nothing; an unreadable selection fails rather than being pasted over; terminals get a write with no field context; a failed Super is still kept in History (text = the dictation, nothing pasted); Super skips sent-text capture (its answer isn't a correction of what was said). The hint is shown at key-down, when the selection is read. The clipboard as context waits for B2.
  - Trigger: a dictation that begins with "super mode" or with "super" followed by a pause, written by the engine as "Super," or "Super.". "Super excited to join" doesn't trigger. The word is removed in code (like `CodeTalk`'s leading slash command), and the rest is an instruction.
  - With text selected at key-down, the instruction edits the selection ("super, make this shorter"). `FocusedTextClient` also returns the selection's length. The LLM gets `<selection>` plus the instruction and returns only the new text. Re-read the selection first to check it hasn't changed, then paste over it while it's still active. Cap at 6,000 chars like `FieldMerge`; skip terminals.
  - With nothing selected, it writes at the cursor using the field, the app name and the clipboard as context ("super, reply saying I'm in for Thursday").
  - Without "super", nothing changes: a selection is replaced by the dictation, as today.
  - On failure, leave the selection untouched, copy the dictation and show "Super failed: nothing changed".
  - Early detection: while recording, Apple Speech (SpeechAnalyzer, on-device, ~16 MB) transcribes the first ~3 s of live audio only to spot the trigger, so the indicator changes about a second after "super" is said. The final transcript decides; if the two disagree, follow the final one and drop the look. Skipped when the Apple Speech model isn't installed.
  - Look: the capsule stays red, so recording stays unmistakable. Add a thin multicolour rim (angular gradient, low saturation, one turn every ~3 s), one shimmer sweep when Super switches on, and a "✦ Super" pill using the existing pill system. With Reduce Motion the rim is still and there's no sweep. While the LLM works the capsule turns purple as usual and keeps the rim.
  - Hint: the first few times text is selected at key-down without "super", the pill says "Say 'super' first to edit this" (counted in settings, shown 3 times).
  - Settings: `superEnabled` (default on) and `superEarlyDetection` (default on).
  - Model quality: Superwhisper warns that small local models do Super badly. Test the on-device 4B on ~10 edits and ~10 replies (`lsbench rewrite`); if it fails, say so in Settings rather than shipping a bad experience silently.
  - Verify: HexCore tests for the trigger rules (with and without a pause, "super excited", "Super mode,"). A TCA test for the edit path, including a failure that leaves the selection alone. Live in Mail, Notes and Slack.
- **B2. Clipboard context** (Superwhisper, VoiceInk). Setting `clipboardContext`: **on for on-device rewrite, off for every other endpoint** unless the user turns it on there too (Settings > AI Rewrite > Advanced).
  - What's taken: the last text copied up to 3 s before key-down or during recording. A 0.5 s `changeCount` poll records when the clipboard changed.
  - What's ignored: the app's own paste and restore, items marked `org.nspasteboard.ConcealedType`/`TransientType` (password managers) and non-text items. Capped at 2,000 chars.
  - It reaches Super and Clean as `<clipboard>`: in Clean only to spell names; in Super also to resolve "this/that".
  - Verify: unit tests for the time window and the ignored types; a test that our own paste isn't picked up.
- **B3. Per-app modes and tone.** The user **picks the apps**: an explicit list in Settings, filled from running apps or an app picker, never learned from switching. Each row is app → mode (+ tone: casual / neutral / formal). It applies at key-down for that dictation; the ⌃⌥ cycler still overrides, and a pill shows the chosen mode. Unlisted apps use the current mode.
  - Setting `perAppModesEnabled` (default off). The list starts empty, with a "Suggested" button that offers terminals/IDEs → Prompt, chat apps → Clean casual, Mail → Clean formal.
  - This is the light version of P2's Mode model. Engine and provider per mode stay deferred.
- **B4. Undo-AI-edit hotkey.** Right after a paste, a shortcut replaces the pasted text with what was heard. It checks through AX that the pasted text sits right before the cursor, selects that range (`kAXSelectedTextRangeAttribute`) and pastes the raw text. If the check fails it does nothing; no ⌘Z, since undo differs per app. Setting `undoRewriteHotkey` (default unbound). Spec it in `docs/hotkey-semantics.md` together with `HotKeyProcessorTests`.
- **B5. MCP server** (Wispr Notetaker, Monologue, Spokenly). Setting `mcpEnabled` (default off) with a switch for each kind of data: Notes, dictation history, sent text.
  - Shape: a helper (`legacyscribe-mcp`) inside the app bundle, started by the agent over stdio, so no ports or network sockets. Settings has "Copy setup command" for Claude Code (`claude mcp add legacyscribe -- /Applications/LegacyScribe.app/Contents/MacOS/legacyscribe-mcp`), Claude Desktop and Codex. It reuses HexCore's `ScribeStore` (opened read-only; WAL allows readers while the app writes) and the Notes file code. Check the current Swift MCP SDK before starting.
  - Read tools: `search_dictations(query, since, app, limit)` (needs an FTS5 table in `scribe.sqlite`), `recent_dictations`, `list_notes`, `get_notes` (`notes.md`), `get_transcript`, `get_vocabulary`, `get_corrections`.
  - Tools that change something go through the running app, never straight to the database: `add_vocabulary`.
  - `ask_by_voice(question)` (own switch, built last): the indicator shows the question, the user holds the key and answers, and the text goes back to the agent. It needs a local channel to the running app (a Mach port, not a socket, so Private mode's zero-socket rule holds).
  - Privacy: results go to the agent's model, usually a cloud one. The helper refuses everything while Private mode is on, caps result sizes, logs each call (`HexLog.mcp`), and Settings shows when it was last used.
  - Verify: a test client lists the tools and calls each one against a scratch data root. With Private mode on, every call is refused.
- **B6. Sync folder** (instead of a hosted sync server, which would cost money and make us custodians of the data). Setting `syncFolder` (default unset).
  - How it works: the user picks a folder in iCloud Drive, Dropbox, Google Drive or Syncthing. Each Mac appends only its own change files (`devices/<device-id>/<yyyy-MM>.jsonl`: dictations, corrections, vocabulary, notes) and merges the other Macs' files into its own `scribe.sqlite` by UUID, newest edit winning.
  - Kept out: the database itself never goes in the folder (a synced live SQLite file corrupts), and so do audio and API keys. Writing pauses while Private mode is on.
  - CloudKit was the alternative: free for us, but it needs the paid Developer Program, an iCloud entitlement and a provisioning profile, which this app's signing has none of.
  - It only pays off with two Macs or a future iPhone app. The Notes export folder already covers notes.

*C. Later, no decision needed yet.* A live preview from Apple Speech's provisional results while Cohere does the final pass (B1's early detection is the first step). Vision OCR as a context fallback for apps whose AX tree is empty (needs Screen Recording). Muffling other audio (Superwhisper 2.19) instead of pausing it.

*Not adopting:* a hosted sync server, team dictionaries, bot-free meeting capture of system audio (revisit for Notes), training our own speech model (P4.5/P5 is our version).

**P3.6: Hackathon round (planned 2026-10-13).** The user wants to enter the app in a hackathon at their school (Hack-A-Roo), so other people have to be able to install it, trust it and run it on their own Mac. This round comes before `lsbench vocab` and the rest of part B. The user's favourite mode so far is Clean; Prompt hasn't had a real try yet. **Order:** housekeeping, D1, D2, D4, D6 (the demo feature), D3. **Changed 2026-10-14:** D2 and D3 come first (cold microphone, lighter at rest), then D1, D4, D6. D5 is research only. Open questions: the hackathon date, and whether its rules accept a project started before the event.

*The event (read 2026-10-15 from udica-site.vercel.app/events/fall-2026-hack-a-roo).* Hack-A-Roo 2026 is a poster competition: Fri 13 Nov, 9:00–12:00, MNLC 352, attendance required. Judges review every poster and pick finalists, who give a 5-minute talk with the poster on screen. Deliverable: one 48 × 36 in landscape PDF poster (problem, solution, implementation, results, limitations, impact; name the external tools, datasets and models used), due **Mon 9 Nov, 23:59 Central**, which is also when Build Track registration closes. A working prototype is expected; no video or repo is asked for. Build Track ("bring your own idea", AI / Data Science or Quantum): up to 4 students, solo allowed, a faculty mentor required. Judging, 20% each: creativity, innovation, impact, completeness and technical execution, excitement and presentation. Only UMKC students win cash. Prior work: "class work you want to take further" is allowed, but the project "should be substantially developed by the student team during the Hack-A-Roo project period", whose dates aren't given. Ask at the Zoom Q&A (Fri 16 Oct, 13:00), and declare the Hex fork on the poster. *Answered at the Q&A (2026-10-16, the user asked):* a project you're already working on, or a class project, is fine for the bring-your-own-idea track as long as it fits AI or quantum. Submission is the form that matters (by 9 Nov, rolling); registration is only a headcount. The organisers print the posters; arrive before 9:00 on 13 Nov to set yours up. AI mentors contact the teams.

*Poster sub-headline idea (user, 2026-10-15):* "We do it, ~~but like~~ better." (the crutch word "like" struck through: the coach counts it). Wispr and Superwhisper dictate too; the coach is the "better".

*Order changed 2026-10-15 for the poster event:* the judges see a poster and possibly a live demo rather than strangers installing the app, so D6 (the speech coach, the innovation story) comes next, after D1's live check and D3's idle figure. D4 shrinks to its minimum (don't let an 8 GB Mac download a model it can't run). The week before 9 Nov is kept for the poster; its results come mostly from numbers already measured (WER per engine on the user's voice, key-up → paste latency, idle memory, Private mode's zero sockets, Notes surviving kill -9). The user registers for the Build Track and finds a faculty mentor.

*Housekeeping.* Commit the work since 2026-10-08 in feature-sized commits (62 tracked files and the untracked new ones were uncommitted on 2026-10-13, in a Syncthing folder). Try Legacy live (B1 is built but not tried live) with the sparkle on the capsule.

- **D1. Notes mode: holding dictates, only a tap starts a session.** Holding the talk key out of habit while in Notes mode starts a session on release: `NotesTapDetector` counts any clean press as a tap, however long it's held. The session then records until the next tap and lists a one-second note.
  - A tap becomes a press released within 0.3 s, the double-tap window in `docs/hotkey-semantics.md`. A longer hold is an ordinary push-to-talk dictation in the mode used before Notes (Clean if none), with the pill "Notes mode: dictated as Clean". Notes mode stays picked.
  - Safety net: a session stopped in its first 5 s, or one where the VAD found no speech, is deleted instead of listed, with the pill "Notes session discarded". Esc in the first 10 s discards rather than saves.
  - Change the spec in `docs/hotkey-semantics.md` ("Notes mode") together with the detector's tests.
  - *Built 2026-10-15, not yet tried live.* Every press in Notes mode starts a dictation at key-down, so a hold loses no words; `NotesTapDetector` (now timed) runs alongside `HotKeyProcessor`, and a clean release within 0.3 s drops that dictation and starts the session. The dictation's start sound waits out the 0.3 s so a tap makes one sound, and the "dictating as" pill shows only after it. A session in which nothing was heard is deleted when its transcription finishes (`NotesTranscript.heardNothing`: no words and no failed chunk). The mode before Notes is a setting (`rewriteModeBeforeNotes`, kept by `rewriteMode`'s `didSet`); a dictation switched to Notes mid-way now uses it too instead of pasting as recognized. Tests: `NotesTapDetectorTests`, `HexSettingsMigrationTests`, `NotesModeTests` (5).
  - *Checked 2026-10-17 on real engines, no microphone (`tools/notes-taptest.py`, results in `docs/bench-results.md`):* a 0.15 s tap starts a session and nothing is pasted, a 4 s hold is one Raw dictation (Clean on the on-device 4B too), 0.25 s releases start a session and 0.40 s ones dictate, a second tap 3 s in discards the session. Still not tried with the real key and microphone: the physical Right ⌥ event path and the pill/sound timing as seen and heard.
- **D2. Microphone indicator only while recording.** The orange dot stays in the menu bar because Super Fast Mode (`superFastModeEnabled`, default on, Settings > General) keeps the capture engine running between dictations for its 0.45 s pre-roll. macOS shows the dot whenever an app holds the microphone. Wispr Flow's requirements page: "Flow accesses the microphone only while you actively use it."
  - Measured 2026-10-13 on the M5, Debug app idle with the mode on: 1.2% CPU, ~570 idle wakeups a second, 613 MB.
  - Measure with the mode off: key-down → first sample, and whether the first word gets clipped when speech starts with the key press (built-in mic and AirPods, 20 tries each). Check that Legacy's early detection (`recordingHead`) works without the warm engine.
  - If the cold start costs ≤150 ms and loses no words, turn it off for fresh installs and say what it costs in Settings ("Keep the microphone ready: macOS shows the microphone dot the whole time"). If words get clipped, try a warm window of 60 s after each dictation before settling on always-warm.
  - **Done 2026-10-14.** Cold start 0.19–0.24 s in 10 of 12 tries (Release, built-in mic), 0.76 s and 1.19 s in two, both spent arming `AVAudioEngine`. The user noticed no lost first word on the built-in mic or AirPods, so it's off for fresh installs as "Keep the microphone ready". `armEngine` now logs node/prepare/start times so the slow starts can be traced. Legacy's early detection with a cold engine: **checked live 2026-10-15** (the user: "Legacy" is heard and the pill changes).
- **D7. Undo a cancel (built 2026-10-14, user request).** A press while the last dictation processes no longer cancels it, and Esc offers Undo for `cancelUndoSeconds` (default 30 s). See the CLAUDE.md row and `docs/hotkey-semantics.md`. **Checked live 2026-10-14:** the user confirmed everything about the Undo button works.
- **D3. Lighter at rest.** Profile the idle app (Instruments Energy Log, `top -stats cpu,idlew,power`) with each part turned off in turn: the warm microphone, the loaded Parakeet/WhisperKit models, the event tap, the retention timer. Goal: no wakeups that come from the app while idle with a cold microphone, and an idle memory figure for the README. Unloading Parakeet after a quiet spell is a candidate only if its reload is under ~0.5 s (the Cohere decision notes Core ML reloads can take seconds). **Measured 2026-10-14** (Release, cold mic): 0.0% CPU and 0 idle wakeups over 30 s, but 416 MB footprint. The memory was an MLX leak on every Cohere/Qwen load (~7–12 MB each): an mlx-swift bug, fixed in a fork (upstream PR ml-explore/mlx-swift#501), plus an unevaluated RNG key chain. **2026-10-15:** Parakeet v3 costs ~52 MB in the process while loaded and reloads in 0.17 s, and unloading frees nothing measurable, so it stays loaded (bench-results). The fork now also survives `a._updateInternal(a)` (`37407d1`); a freshly launched Release app sits at 135 MB with 1 live MLX array. Still to do: the idle footprint after ~10 dictations on Cohere, for the README. WhisperKit isn't measured (no model downloaded). **Overnight 2026-10-17** (Release, `tools/idle-profile.sh`, 2 min warm-up then 5 min of `top` every 5 s; median CPU and power, footprint once):

  | config | CPU % | idle wakeups/s | power | footprint |
  |---|---|---|---|---|
  | baseline (cold mic) | 0.0 | 0 | 0.0 | 86 MB |
  | microphone kept ready | 0.3 | 0 | 0.3 | 86 MB |
  | Cohere selected | 0.0 | 0 | 0.0 | 85 MB |
  | Cohere + microphone ready | 0.3 | 0 | 0.3 | 95 MB |
  | Private mode | 0.0 | 0 | 0.0 | 82 MB |

  Idle footprint for the README: **~86 MB** with a cold microphone. `top` reported 0 IDLEW on all 61 samples of every config, even with the microphone running at 0.3% CPU, so it probably doesn't see the audio thread's wakeups; Instruments' Energy Log would settle it. Cohere is never loaded at rest (load-per-dictation), hence no difference.
- **D4. Check the Mac before any download.** Each model in `models.json` gets its disk size, the memory it needs while loaded and a speed class measured on the M5. Before downloading, the app reads the chip, memory and free disk: a model that won't fit is greyed out with the reason ("needs 16 GB of memory; this Mac has 8 GB"), and one that fits but will be slow says so. The first run suggests a default for this Mac and shows its size before downloading (8 GB: Parakeet v3 and the 1.7B or no on-device rewrite; 16 GB or more: Cohere and the 4B). Measure on an 8 GB M1, borrowed if needed: Cohere and the 4B loaded together peak near 3.7 GB on top of the app.
  - *Minimum built 2026-10-16 (`ModelFit`, design B of the mock-ups):* a model that isn't downloaded and won't fit is dimmed with an orange "Won't fit" badge, its reason in a popover on an info icon (memory first, then free disk at download size + 10%), Download disabled. Minimum memory: Qwen3 1.7B 8 GB, 4B 16 GB, 8B 24 GB (the rows' existing copy), Cohere 8 GB (~2 GB loaded; next to the 1.7B on an 8 GB Mac); speech models without `minMemoryGB` are checked for disk only. Not done: speed class, first-run default per Mac, the 8 GB M1 measurement.
- **D5. Intel Macs (research, not building).** The app needs macOS 26 (SpeechAnalyzer), and only four Intel Macs run macOS 26: the 2019 Mac Pro, the 2019 16-inch MacBook Pro, the four-port 2020 13-inch MacBook Pro and the 2020 27-inch iMac. macOS 27 is Apple Silicon only. MLX, which runs Cohere and the on-device rewrite, needs Apple Silicon. Wispr Flow covers Intel Macs because it transcribes in the cloud.
  - An Intel build would need an x86_64 slice without MLX (check that FluidAudio's `NemoTextProcessing` Rust xcframework ships one) and an engine that runs there: WhisperKit on the CPU/GPU (slow), Apple Speech (Intel support unverified), or cloud speech-to-text with the user's key. Rewrite would go through a hosted key or Ollama. Reaching older Intel Macs means lowering the deployment target and losing SpeechAnalyzer and every macOS 26 API.
  - Not for the hackathon. If pursued: confirm `SpeechTranscriber` on an Intel Mac running macOS 26, and check that the packages build for x86_64.
  - 2026-10-14: the user asked about lower-end Intel Macs. Most can't run macOS 26 at all, so for them the app would need a lower deployment target and no SpeechAnalyzer: effectively a different app. The cheap reach is the 8 GB Apple Silicon Mac (D4).
- **D6. Speech coach ("train the person, not the model").** An optional tab that shows how the user speaks and how to improve it. No competitor does this: Wispr's Insights shows words per minute and one "corrections" count with filler words folded in.
  - Off by default. At the very bottom of Settings: a toggle, "Open Speech Coach", and "Turn off and delete coach data" (with a confirmation; it deletes the coach's stats only, never History).
  - Counts: ums, uhs, ahs, ers; self-corrections and restarts ("no", "I mean", "scratch that", "actually", a repeated word); words per minute; pauses, with the average pause between sentences, the average pause within a sentence (between thoughts) and the longest pause. Shown overall, per week (trend) and per mode or app.
  - Data: each History entry's heard text (`rawText ?? text`, before the rewrite) for counts, and word timings (`WordMatcher` on Parakeet TDT, already used for playback) for pauses and pace on entries that still have audio (30 days). Older entries give counts only. Turning it on analyses everything already in History, so it starts with the user's past dictations rather than an empty page. Read-aloud practice recordings are read speech, so they're kept out of the counts (or shown separately as "reading").
  - Main risk, verify first: speech engines often leave fillers out of the transcript. Count the ums by ear in 10 of the user's recordings and compare each engine's transcript. If the engines drop them, detect hesitations from audio instead: a gap between words that has voice in it (Silero VAD) is a filled pause, counted without knowing which sound it was.
  - Tips: rule-based first ("most of your ums come in the first two seconds: take a breath before you start"), then a weekly summary from the on-device model. Drills reuse the read-aloud Practice sets (for example, read a line and pause instead of saying um).
  - Local only: derived tables in `scribe.sqlite` (rebuildable from History), nothing sent anywhere, and it works in Private mode.
  - *Risk check 2026-10-15 (bench-results, "Fillers in transcripts"):* Parakeet v3 and Apple Speech write the user's ums (9 and 8 in 10 clips, agreeing), Cohere drops two in three. The coach counts fillers from a Parakeet v3 pass over each recording, so only entries with audio; Cohere's text still gives self-corrections and pace. A sound-only filled-pause detector failed (3 of 8). *By-ear count 2026-10-15:* 8 fillers by ear, and Parakeet v3 wrote every one (plus a real "uh" said as a question); v2 and Apple Speech each missed one (bench-results).
  - *Decided 2026-10-15 (user):* Cohere is out of the coach. Parakeet v3 transcribes the recordings again (Apple Speech when no Parakeet model is downloaded), and nothing runs on its own: a **Run analysis** button goes through every History recording not yet analysed, counts and aggregates. Results are stored per dictation (`coach_clips` in `scribe.sqlite`, deleted with the entry), so a rerun only does new recordings and stats outlive the 30-day audio. *Analysis built 2026-10-15* in HexCore (`Coach/`: `CoachText` fillers and corrections, `PauseFinder` pauses from loudness, `CoachSummary` totals/weeks/modes/apps/tips, `coach_clips` table as migration `v3`, `SpeechCoachTests`), checked on real clips with `lsbench coach`. Pace is reported without pauses and pauses as medians (bench-results). *Layout picked 2026-10-15:* option C, the scorecard (mock-ups in `<data root>/bench/coach-mockups/`, script `mock.swift`): its own Coach tab led by one big number (fillers per 100 words) with its trend, the weekly chart, three smaller numbers, tips as cards, and Run analysis top right. *Extras picked 2026-10-15:* a filler-free minute (60 s on a random topic, filler count and best score, the live demo), crutch words and hedges per 100 words, "say these more clearly" (words an engine misheard: two engines disagreed or the user fixed the word before sending; Vocabulary names left out), pitch range, sentence length and run-ons, and a share card (PNG of the scorecard, for the poster). Not picked: goals and streaks, trailing off. Mock-ups `C2.png`, `minute.png`, `share.png` beside the others. Stuttering raised by the user: no stutter score (see the reply that day); at most an opt-in "I stutter" setting that stops counting repetitions and blocks against the user. *Approved 2026-10-15:* the mock-ups, and the opt-in "I stutter" setting (framed as a positive option). The user proposed audio snippets of their own moments (a few seconds around a filler); proposal back: play them from the original recording at the stored word times (no audio copies, so the 30-day rule still holds), pair each with a moment the user got right, none of repeats with "I stutter" on, never on the share card. Critique sent the same day: "say these more clearly" counts only words both engine families got wrong (as `PracticeGrade` does), pitch range shown only for the filler-free minute, "like"/"just" counted only in filler use, run-ons from "and" chains rather than the engine's full stops. *Notes in the coach, proposed 2026-10-15:* the user asked for meeting speech (Notes) in the coach, told apart by voice. Notes delete each chunk's audio once transcribed, so the coach would count while the chunk exists: a second Parakeet pass per chunk (~0.25 s, Neural Engine, beside Cohere on the GPU) keeping counts only, no text or audio; the notes text stays Cohere (5.3% vs 8–9% WER, no ums). Only stretches matched to the user's voice count: FluidAudio's speaker embeddings (CAM++, `enrollSpeaker` on its diarizers) enrolled from the read-aloud recordings. Risk check first: how often a laptop mic across a table mixes the user's voice up with others', especially stretches under ~2 s. Order: the dictation coach first, then the voice check, then Notes counting if it passes. *Decided 2026-10-15 (user):* the voiceprint is its own thing, not coach data: it also serves speaker labels in Notes (who said what), stays on this Mac, and is deleted only when the user explicitly asks; "Turn off and delete coach data" leaves it alone. *App side built 2026-10-15:* the Coach tab (layout C with the extras), Run analysis, snippets, the filler-free minute sheet, the share card, the Settings section and "I stutter" (CLAUDE.md row "Speech Coach"); `SpeechCoachTests` (311 HexCore tests), `CoachFeatureTests` and `CoachSnapshotTests` pass. Not yet tried in the running app. Next: the user tries it on their History, then the voiceprint check and Notes counting (a client running Parakeet over History recordings, the tab, the Settings toggle). *First live test 2026-10-15:* the user found "you paused instead" snippets in which they were still talking, away from the microphone. Fixed: a Silero VAD and Parakeet-word veto on loudness silences was built, then dropped after two by-ear checks found most vetoed stretches silent (15 of 20, then 22 of 25 with the edge frames ignored); pauses are loudness only (bench-results), and the good example is now a clean sentence played whole (user's pick over stricter pauses). Also added at the user's request: "So"/"Oh" opening a sentence count as crutch words. Card look: mock-ups `look.png` (options A–D); the user picked B, a grouped-form fill and hairline on the window background, matching the other tabs (applied; the snapshot test now resolves system colours under the drawing appearance, which is why the earlier one looked flat). *Pauses, 2026-10-15:* after two by-ear checks the Silero and Parakeet-word vetoes were dropped; pauses are loudness only (bench-results). *Voiceprint check, first results 2026-10-15* (`lsbench voice`, CAM++ enrolled from the read-aloud lines, against LibriSpeech and `say` voices): EER 12.6% on 1 s stretches, 7.3% on 2 s, 5.2% on 5 s, so short turns can't be decided by voice alone; same-room voices through the user's microphone not yet tested (bench-results). *Follow-up the same evening:* FluidAudio's WeSpeaker v2 (the diarizer's embedder) enrolled from 40 History dictations does far better: EER 5.0% at 1 s, 1.2% at 2 s, 0.8% at 5 s, and no others let in from 2 s up at 95% of the user accepted. In two dictations made with a video playing in the room, 2 s windows over the user scored 0.45–0.73 and over the video alone −0.02–0.32 (bench-results). Pending: decide with the user whether Notes counting goes ahead on WeSpeaker. *User feedback 2026-10-15:* "Said cleanly" examples still had repeats: restarts of up to 5 words now count as repeats (clean sentences 102 → 93). The trailing "Thank you." in dictations was Cohere on silence and on slivers left by mlx-audio's splitter: fixed with `CohereChunks` and the speech gate on dictation (bench-results). *Live check 2026-10-15:* the running Debug build (20:59) predated both fixes: a false "Thank you." came back on a 27.2 s dictation (reproduced with mlx-audio's splitter, gone with `CohereChunks`), and "Said cleanly" sounded clean on version 4 clips. Both still need a check after a rebuild.

- **Overnight queue (built 2026-10-16).** `tools/overnight.sh` runs the heavy jobs one after another under `caffeinate -i`: `idle` (the D3 idle profile, `tools/idle-profile.sh`: Release build, then baseline / fast mic / Cohere / Cohere + fast mic / Private mode, each 2 min warm-up + 5 min of `top` and `footprint`; it edits the real `hex_settings.json` because Release ignores `LEGACYSCRIBE_DATA_ROOT`, and a trap restores it), `notes-long` (signed Debug build, then `notes-crashtest.py` with a 2 h and a 60 min feed looped from `qa-10min.wav`; inputs kept in `<data root>/bench/overnight-inputs/`), and `label-27b` (resumes the Notes labeller once the GPU is free). After it, `finetune-17b` trains the 4-bit Qwen3-1.7B on the dictation pool plus the Notes pieces the 27B labelled (`tools/finetune/build_notes_mix.py`; batch 2 x accumulation 2 with gradient checkpointing, at most 400 iterations; skipped if `label-27b` failed or under 100 pieces pass the filter), keeps the lowest-validation-loss checkpoint as `scribe-1.7b-qnotes-4bit`, and logs its WER next to the Heavy + paragraphs model's 29.7 / 0.340.
  - Start it before bed with nobody using the Mac: `tools/overnight.sh` (`--only a,b`, `--skip a,b`, `--dry-run` to see the plan). It quits LegacyScribe and opens it again at the end (`reopen-app.txt` records which build).
  - Results: `<data root>/overnight/<date>/` holds `<step>.log`, `status.tsv`, `idle/idle-table.txt` and `summary.txt`. Copy the idle table into this D3 item and the crash-test figures into bench-results when read.

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

**Notes mode (planned 2026-10-09, built 2026-10-10).** Ramble hands-free for up to 2 h, then get a list of notes. Cohere transcribes during the session and a local model writes the notes afterwards. Two goals rank above everything else: **no data is lost**, and **memory stays flat** however long the session runs.

*Why the dictation path can't be reused.* It writes one 32-bit WAV to the system temp folder (`RecordingClient.makeCaptureRecordingURL`) and transcribes it in one call after key-up (`CohereClient.transcribe`). It also deletes the audio when transcription fails (`TranscriptionFeature.handleTranscriptionError`), and Esc discards the recording.

*Recording.*
- Notes is a fourth mode in the ⌃⌥ switcher (⌃⌥4). In Notes mode a clean tap of the talk key starts a session and the next one stops it (`NotesTapDetector`, see `docs/hotkey-semantics.md`). Esc stops and keeps the session. A tap within 0.6 s of the start is ignored, so a habitual double-tap doesn't end it. Dictation is blocked while a session records.
- Capture is its own `AVAudioEngine` (`NotesCaptureController`) on the input chosen in Settings, so `RecordingClient` is untouched. A device change rebuilds the engine and the session carries on. A crash loses at most the ≤30 s still in memory.
- Idle sleep is blocked for the session (`SleepManagementClient`).
- The capture writer keeps up to 30 s of samples in memory and writes a 16-bit WAV chunk to `<data root>/Notes/<session>/pending/<index>.wav`. Each chunk is cut at the quietest point between 20 and 30 s, the same rule `CohereClient` uses, so adjacent chunks join without splitting a word. A chunk is ~0.8 MB.
- At 1:55 an indicator pill warns that the session is about to end. At 2:00 the session stops and goes on to notes. The cap keeps the transcript and the notes pass bounded.

*The transcribe loop.* This runs during the session, one chunk at a time, in index order:
1. Silero VAD finds the speech in the oldest pending chunk; only that speech goes to Cohere (~0.8 s per 25 s, so it keeps up live). A chunk with none is recorded empty, and a transcript that is one phrase looped is dropped (`NotesSpeech`). Ten minutes without speech stop the session (`NotesSilenceWatch`): fed silence or room noise, Cohere invents looping sentences.
2. Write the full transcript plus the new chunk to `transcript.new` and fsync it.
3. Rename `transcript.jsonl` to `transcript.bak`, then rename `transcript.new` to `transcript.jsonl`.
4. Delete the chunk's WAV. This happens only after step 3, so a transcribed chunk always exists in at least one file.

The transcript is JSONL with one line per chunk (`{"chunk": n, "text": "…"}`). The chunk index makes recovery idempotent: a chunk already in the transcript is never added twice. 2 h is ~20K words (~150 KB), so rewriting the file every 25 s costs nothing.

*Cohere resets.* Cohere stays loaded for the session. It is unloaded and reloaded (~0.4 s) after an error, or when the process footprint crosses a threshold. Capture never pauses for a reset: the queue is the `pending/` folder on disk, so chunks stack up there and the loop drains them once Cohere is back. A chunk that fails twice is moved to `failed/` rather than deleted, and a `{"chunk": n, "gap": true}` line marks the hole. Disk use is a few pending chunks plus the transcript. Notes sessions keep no audio. This departs from the 30-day retention rule on purpose: the transcript is the record.

*Notes.*
- Cohere is unloaded first, so the two models are never resident together. Notes wait while another session records.
- The transcript is split into pieces of ~1,500 words at chunk boundaries. Each piece goes to Ollama (`qwen3:8b` by default), one request at a time, waiting for each answer. Each answer is saved as `notes/part-NN.md` the moment it arrives.
- Requests use Ollama's own `/api/chat` (`OllamaChatAPI`), not its OpenAI-compatible `/v1`: only the native API takes `num_ctx`. It is 16,384 on every call, because a different `num_ctx` makes Ollama reload the model. `think: false`, 600 s per request.
- A final pass merges the parts into `notes.md`: topics, one bullet per point, action items, open questions. Like Prompt mode, it keeps every point and invents nothing. If the merge fails (or is cut off at the context limit), the parts are joined under "Part N" headings instead, so a session always ends with notes.
- A notes failure (Ollama not running, say) is shown on the session with a Retry button; the next launch retries once on its own.
- If an export folder is set, `notes.md` is also copied there as `Notes <session>.md`.
- Ollama runs as a separate process, so if the model runs out of memory or crashes, the app and the transcript are unaffected. Nothing waits on a paste, so there's no timeout pressure.

*Built 2026-10-16 (spec and decisions in `DESIGN.md`, "Notes speaker labels"; CLAUDE.md row "Notes speaker labels"). Q&A recording (18 min): 8 speakers, "You" only at 0:46–1:44 and 14:47–15:12. Naming speakers built the same day (option A: chip popover, named voiceprints recognised in later sessions; CLAUDE.md row "Naming speakers"). Crash test with labels: all pass (bench-results). Open: a solo-session check with labels on. The 2-hour memory run passed overnight on 2026-10-17: flat, 3.42 GB against 3.45 GB for 10 min (bench-results).* *Original plan, kept for the record:* Cohere has no timestamps, so speakers must be split before transcription: diarize each chunk (FluidAudio's pyannote segmentation + WeSpeaker embeddings), transcribe each speaker turn separately, and keep one centroid embedding per speaker for the whole session so "Speaker 2" in chunk 40 is the same person as in chunk 3 (match by cosine distance, add a new speaker past a threshold, update the centroid with each turn). The user's own voice can be enrolled from the practice recordings and labelled by name. Turns under ~1 s carry too little voice to embed; they inherit the neighbouring speaker.

*Built 2026-10-16 (spec and decisions in `DESIGN.md`, "Notes trimming"; CLAUDE.md row "Notes trimming"): Trim on the Transcript tab leaves sentences out of the notes through a drag or click selection and a timeline strip, stored in `trims.json` beside an unchanged transcript; "Write notes again" applies them. Unit and app tests pass; `tools/notes-crashtest.py` passed with the `seconds` field (overnight 2026-10-17, spec 10c). Not yet run: the 18-min Q&A check by hand (spec 10b) and a session recorded before `seconds` (10d).*

*Crash recovery.* `session.json` holds the stage: `recording` → `transcribing` → `noting` → `done`. On launch, an unfinished session resumes:
- The transcript is the newest valid file among `transcript.jsonl`, `transcript.new` and `transcript.bak`, judged by the highest chunk index on a fully parsed last line.
- Pending chunks with a higher index go back into the loop.
- Notes generation restarts after the last `part-NN.md` already saved.

*UI.* A Notes tab: the list of sessions with their stage and progress, each with its notes, its transcript, Copy, Export Markdown, Reveal in Finder, Retry (or "Write the notes again") and Delete. With no session selected it shows how Notes works and its settings (Ollama URL, model, export folder). The indicator records while a session runs, with a "Notes" pill that counts up, a warning at 1:55 and "Saved: writing notes" when it stops.

*Verified 2026-10-12* with `tools/notes-crashtest.py` (the Debug app's headless `--notes-harness`, real Cohere/VAD/notes writer, scratch data roots): kill -9 while recording, while transcribing (20+ chunks queued), while writing notes, and after the first of two note parts was saved, then relaunch: every chunk that was on disk came back exactly once with the uninterrupted run's text, nothing stayed in `pending/`, the saved part was kept, and notes were written. Forced Cohere failures: a chunk that failed once matched the reference after the reload; one that failed twice became a gap with its audio in `failed/`. Memory: see `docs/bench-results.md`. The run also found two bugs, both fixed: the Debug app crashed at launch on a FluidAudio VAD assertion, and the on-device notes writer sometimes looped to its token cap.

*Verify.*
- An `lsbench` run over a long recording reports peak RSS. It should be flat between a 10-minute and a 2-hour session.
- `kill -9` during recording, during transcription and during notes, then relaunch: the session resumes with no missing or duplicated chunk.
- Force a Cohere reset mid-session: the chunks stack up in `pending/`, then drain.

*Decided (2026-10-10).*
- Trigger: a Notes entry in the ⌃⌥ mode switcher (and ⌃⌥4), not a new hotkey.
- Where notes go: the Notes tab, plus an optional export folder (`notesExportFolder`) that gets a copy of each session's notes.
- Merge: local Ollama only. OmniRoute is never used for notes.

*Build approach.* Keep both tokens and wall-clock time low:
- Build the recording, transcribe loop and recovery first. They carry the data-safety risk.
- Reuse `CohereClient` (a second instance, kept loaded for the session). Ollama goes through its native API instead of `RewriteClient` (see Notes above).
- Put the transcript file logic and the recovery rules in `HexCore`, where unit tests cover them, rather than in the app (`HexCore/Sources/HexCore/Notes/`, `NotesTests`). The app side is `NotesCaptureController`, `NotesClient` (`NotesEngine`), `TranscriptionFeature` and `Features/Notes/`.

## Riskiest assumptions → how we verify
| # | Assumption | Verify | When / fallback |
|---|---|---|---|
| 1 | Cohere 4-bit runs in-process in Swift at < 500 ms for a warm 10 s clip on the M5 | `lsbench` numbers | P0. Fallback: 8-bit or fp16, or Parakeet as the default |
| 2 | 4-bit doesn't hurt WER on my voice | `lsbench` WER across quantizations on my fixtures | P0 |
| 3 | The CTC aligner gives usable word timings (±80 ms) for Cohere | Compare against Parakeet/Whisper timings on the same clips | P1. **Failed for CTC 110M** (median ~600 ms on exact synthetic boundaries). Fallback taken: Parakeet TDT timings moved onto the words, median 51 ms, 77% within 80 ms |
| 4 | ⌘V paste works everywhere | Matrix: VS Code, Cursor, Slack, Discord (Electron); Safari, Chrome, Arc; Terminal, iTerm2, Ghostty; Xcode, Notes, Messages; a password field (must refuse). Check the restored clipboard and that clipboard managers ignore the transient item | P0; re-run each phase |
| 5 | AX gives field text in Electron and Chrome | Context-dump debug panel per app | P3 |
| 6 | Hex builds cleanly on Swift 6.3 with current FluidAudio and argmax-oss-swift | P0 step 1 | P0. Fallback: start from scratch, porting Hex modules |
| 7 | TCC (Accessibility, Input Monitoring, Mic) grants survive rebuilds | Stable signing identity; rebuild twice and confirm no re-prompt | P0 |
| 8 | Private mode truly makes no network calls | Unit test plus `nettop -p $(pgrep LegacyScribe)` during Private dictations | P2. **Holds** in `PrivateModeTests` (no request attempted, no internet socket opened during a real on-device dictation); `nettop` on a live dictation is still a manual check |
| 9 | Some engine is LoRA-tunable and loadable back into Swift | P4.5 spike | Before P5 is committed |
| 10 | Memory fits: Cohere-4bit (~1.6 GB) + local LLM (~2.5 GB) + Parakeet, all resident | `lsbench` peak RSS; unload idle engines | P2 |
| 11 | A notes session loses nothing and its memory stays flat up to 2 h | `kill -9` at each stage, then relaunch; `lsbench` peak RSS on a 10-minute and a 2-hour session | Notes mode. **Holds** (2026-10-12, `tools/notes-crashtest.py`): every kill case recovered exactly; transcribing peak 2.13 GB at 10 min, 2.24 GB at 2 h |

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
