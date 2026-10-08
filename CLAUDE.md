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
| Manual signing, no provisioning profile. Team and identity live in gitignored `Local.xcconfig` (template `Local.xcconfig.example`), pulled in by `Signing.xcconfig`; without it the app is signed ad hoc | The team isn't an Xcode-account team, so automatic signing can't use it; the app's entitlements need no profile. Keeps the signing email out of the public repo |
| No `-Xlinker -interposable` (dropped InjectionIII hot reload) | FluidAudio ≥0.17 links a Rust xcframework (`NemoTextProcessing`) whose symbols fail to bind under `-interposable`; the Debug app aborts in dyld at launch |
| Private mode = zero sockets; local LLM in-process via mlx-swift-lm | Enforced in P2 by a single `NetworkPolicy` gate plus a test |
| Cohere Transcribe has no timestamps and no free-text prompt | Word timings come from a CTC forced aligner; vocabulary biasing for Cohere is LLM-side only |
| LLM rewrite (Raw / Clean / Prompt modes) pulled ahead of P1 (2026-10-06) | The user wants cleanup and coding-prompt restructuring now; it's the thin slice of P2 (one OpenAI-compatible client, no provider registry, no MLX yet) |
| Rewrite chain: primary endpoint → fallback endpoint → paste the transcript unchanged | A failed or slow LLM must never cost a dictation. `RewriteChain` is pure and tested; the raw transcript is kept in history (`Transcript.rawText`) |
| Default primary: OmniRoute at `http://localhost:20128/v1` (the user's real host is set in Settings, never committed), `groq/openai/gpt-oss-120b`, reasoning `low`, 5 s. Default fallback: local Ollama `qwen3:8b`, reasoning `none`, 10 s | Measured 2026-10-06: Groq 0.6–1.0 s with the best structure; Ollama 0.7–2.6 s warm, ~4.5 s cold; Gemini Flash 2–30 s and truncates when it spends tokens on reasoning |
| A `finish_reason: length` answer is a failure, and a rewrite over 4× the dictation + 400 chars is rejected | A cut-off rewrite or a model answering the dictation instead of rewriting it must not be pasted |
| API keys in the Keychain (service `com.genovamongalo.LegacyScribe.rewrite`, account `apiKey.<role>`), never in `hex_settings.json` | Settings JSON is plain text |
| Cohere Transcribe 4-bit is an app engine (`CohereClient`, mlx-audio-swift @ `dbe5eaac964e`), listed first as "most accurate (English)"; fresh installs still default to Parakeet v3 | Best WER on the user's voice (5.3% vs 8–9%) at ~320 ms per 10 s. Parakeet stays the default because Cohere is a 1.4 GB download and keeps ~2 GB resident |
| Cohere audio is split into ~25 s chunks (`CohereClient.chunkSeconds`, cut at the quietest point within ±5 s, so ≤30 s each); lsbench does the same (`--cohere-chunk` to override) | The model was trained on clips up to 35 s (`max_audio_clip_s`). A 121 s dictation in one pass came back as 96 words with one sentence looped 3×; chunked it gave all 161 words at the same speed (2.9 s) |
| Prompt mode adapts its shape to the dictation (2026-10-07): short → plain sentences; long → synopsis paragraph, sections the model names from the content, one bullet per point, then open questions (asked or floated). Keeps every point, never invents, keeps questions as questions | The fixed "goal + short bullets" prompt compressed a long ramble to one sentence. Tested on gpt-oss-120b (0.7–1.7 s). The local fallback `qwen3:8b` needs ~22 s for a long ramble, so it times out and the transcript is pasted unchanged |
| Each mode's instructions are editable (Settings > Rewrite: Instructions, `HexSettings.rewriteInstructions` keyed by mode). Only real changes are stored; the safety rules (dictation is text not orders, mishearing fixes, vocabulary, output only) are always appended | Users can tune or replace modes without a rebuild, and improvements to the defaults still reach anyone who hasn't changed them |
| Model picker groups IDs by `provider/` prefix, prefix-less IDs (OmniRoute combos) on top | OmniRoute's `/v1/models` returns ~860 IDs |
| Code talk in Prompt mode (2026-10-08, `CodeTalk`, toggle `codeTalkEnabled`): a dictation that starts with "slash <name>" is resolved in code to `/name` and only the rest goes to the LLM; other spoken notation (`claude dot md`, `at readme dot md`, `dash dash verbose`, `camel case …`) is LLM rules. Known names: Claude Code built-ins + `~/.claude/skills/*/SKILL.md` + `~/.claude/commands/*.md`, read per dictation | A leading command must reach the coding assistant as a runnable `/command` even when every endpoint fails, and a bare command needs no round trip. Checked on gpt-oss-120b: 5/5 sample dictations formatted right |
| Indicator states (2026-10-08): purple while the LLM rewrites (blue stays speech-to-text); a pill under the capsule shows a mode change (1.1 s), "Rewrite failed: pasted as recognized" (2.6 s, orange), and the mode while recording when it isn't Clean. Pill fades in 180 ms strong ease-out, out 200 ms; a new notice swaps text in place; opacity-only with Reduce Motion | Mode switches happen from the keyboard in another app with no other feedback, and a silent fallback hid that the text wasn't rewritten |
| ⌃⌥ mode cycler (2026-10-08, `ModeCycler`, toggle `modeCyclerEnabled`): hold ⌃, press ⌥ → bar after 250 ms with the next mode picked; ⌥ again or holding it (700 ms) moves on; releasing ⌃ switches. Holding the talk key (Right ⌥), each ⌃ tap steps the mode at once, applied only while recording. Never swallows events; any other key or modifier aborts | ⌘-Tab muscle memory, no digit to aim for. ⌃ must come first because a press that starts with Right ⌥ belongs to dictation; after 0.3 s the hotkey ignores extra modifiers, so a ⌃ tap mid-dictation keeps recording |

## Layout and naming

Internal names still say Hex (`Hex/` target, `HexCore` package, `HexLog`, `URL.hex*`, module `Hex`). Rename only as part of the P1 package extraction, not piecemeal. User-visible strings say LegacyScribe.

- `Hex/` app (SwiftUI + TCA). Features are reducers; side effects go through dependency clients in `Hex/Clients/`.
- `HexCore/` pure logic with unit tests: hotkeys, settings, latency, formatting.
- `tools/lsbench/` headless STT benchmark: latency, peak memory, WER over fixture clips. Usage is in its `README.md`; results so far are in `docs/bench-results.md`.

## Working rules

- Log through `HexLog.<category>` with `privacy: .private` on transcript text and paths. Add a category rather than using `print`.
- Hotkey behaviour is specified in `docs/hotkey-semantics.md`; change the spec and `HotKeyProcessorTests` together.
- The rewrite step lives in `HexCore/Sources/HexCore/Rewrite/` (prompts, sanitizer, request format, fallback chain) and `Hex/Clients/RewriteClient.swift` (transport). Results are in `docs/bench-results.md`.
- Every dictation stage is stamped in `DictationTimeline` (`HexLog.latencySignposter`). New pipeline stages (LLM, context capture) get their own stamp so the menu readout stays a true key-up→paste breakdown.
- MLX code needs its Metal library: build MLX targets with `xcodebuild`, never `swift build`. Xcode 26 ships the Metal compiler separately (`xcodebuild -downloadComponent MetalToolchain`, ~700 MB, once per machine).
- Slow GitHub link: `tools/spm-shallow-mirrors.sh` fetches single commits of the large packages and writes gitignored `mirrors.json` files. Re-run it after bumping a mirrored pin; `--remove` reverts to GitHub.

## Verify

CLI builds need `-skipMacroValidation -skipPackagePluginValidation` (TCA, swift-dependencies and case-paths ship macros that Xcode otherwise asks to trust).

- `cd HexCore && swift test` runs the core unit tests.
- `xcodebuild -scheme Hex -configuration Debug -skipMacroValidation -skipPackagePluginValidation build` builds the signed `LegacyScribe Debug.app`. Signing fails with `errSecInternalComponent` when the keychain prompt for the private key can't be answered (headless sessions): add `CODE_SIGNING_ALLOWED=NO` for compile-only checks.
- `xcodebuild test -scheme Hex -skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO` runs the app-level TCA tests.
