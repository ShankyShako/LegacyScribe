# LegacyScribe — agent notes

Personal, MIT-licensed macOS menu-bar dictation app: hold a hotkey, speak, cleaned text is pasted into the focused app. Local-first; cloud LLMs optional. Hard fork of [Hex](https://github.com/kitlangton/Hex) (MIT, upstream Swift app is frozen): the `upstream` git remote points there.

The phased plan and its risk register live in `docs/plan.md`. Read it before starting a phase.
Before writing an STT engine adapter, read `docs/research/engines.md` (verified API names, versions and caveats per engine).

## Decisions (record new ones here, with the reason)

| Decision | Reason |
|---|---|
| macOS 26+, Apple Silicon only | SpeechAnalyzer needs macOS 26; MLX needs Apple Silicon |
| Unsandboxed, hardened runtime | Reading other apps' text via Accessibility (P3) is blocked in the sandbox |
| Bundle IDs `com.genovamongalo.LegacyScribe` (Release), `.debug` (Debug) | Stable signing identity keeps TCC grants (mic, Accessibility, Input Monitoring) across rebuilds. Debug and Release are separate TCC entries. |
| Data root `~/Library/Application Support/LegacyScribe/` (`URL.hexApplicationSupport`) | Never inside the repo: the repo sits in a Syncthing-synced folder |
| Models under `<data root>/Models/{whisperkit,fluidaudio,mlx}` | `tools/lsbench` and the app share downloads; FluidAudio puts each model in `<root>/<repo-folder>`, so pass any child of the root |
| Retention: raw audio 30 days; text history, correction pairs, calibration audio forever | Pairs are fine-tuning data (P5) |
| Default hotkey: hold Right ⌥ = push-to-talk, double-tap = lock, Esc = cancel | Left ⌥ stays free for typing; side matching lives in `Modifier.matches` |
| Sparkle removed | Upstream feed would "update" this app back into Hex |
| Manual signing with a personal signing identity, no provisioning profile | The team isn't an Xcode-account team, so automatic signing can't use it; the app's entitlements need no profile |
| No `-Xlinker -interposable` (dropped InjectionIII hot reload) | FluidAudio ≥0.17 links a Rust xcframework (`NemoTextProcessing`) whose symbols fail to bind under `-interposable`; the Debug app aborts in dyld at launch |
| Private mode = zero sockets; local LLM in-process via mlx-swift-lm | Enforced in P2 by a single `NetworkPolicy` gate plus a test |
| Cohere Transcribe has no timestamps and no free-text prompt | Word timings come from a CTC forced aligner; vocabulary biasing for Cohere is LLM-side only |

## Layout and naming

Internal names still say Hex (`Hex/` target, `HexCore` package, `HexLog`, `URL.hex*`, module `Hex`). Rename only as part of the P1 package extraction, not piecemeal. User-visible strings say LegacyScribe.

- `Hex/` app (SwiftUI + TCA). Features are reducers; side effects go through dependency clients in `Hex/Clients/`.
- `HexCore/` pure logic with unit tests: hotkeys, settings, latency, formatting.
- `tools/lsbench/` headless STT benchmark: latency, peak memory, WER over fixture clips. Usage is in its `README.md`; results so far are in `docs/bench-results.md`.

## Working rules

- Log through `HexLog.<category>` with `privacy: .private` on transcript text and paths. Add a category rather than using `print`.
- Hotkey behaviour is specified in `docs/hotkey-semantics.md`; change the spec and `HotKeyProcessorTests` together.
- Every dictation stage is stamped in `DictationTimeline` (`HexLog.latencySignposter`). New pipeline stages (LLM, context capture) get their own stamp so the menu readout stays a true key-up→paste breakdown.
- MLX code needs its Metal library: build MLX targets with `xcodebuild`, never `swift build`. Xcode 26 ships the Metal compiler separately (`xcodebuild -downloadComponent MetalToolchain`, ~700 MB, once per machine).
- Slow GitHub link: `tools/spm-shallow-mirrors.sh` fetches single commits of the large packages and writes gitignored `mirrors.json` files. Re-run it after bumping a mirrored pin; `--remove` reverts to GitHub.

## Verify

CLI builds need `-skipMacroValidation -skipPackagePluginValidation` (TCA, swift-dependencies and case-paths ship macros that Xcode otherwise asks to trust).

- `cd HexCore && swift test` runs the core unit tests.
- `xcodebuild -scheme Hex -configuration Debug -skipMacroValidation -skipPackagePluginValidation build` builds the signed `LegacyScribe Debug.app`. Signing fails with `errSecInternalComponent` when the keychain prompt for the private key can't be answered (headless sessions): add `CODE_SIGNING_ALLOWED=NO` for compile-only checks.
- `xcodebuild test -scheme Hex -skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO` runs the app-level TCA tests.
