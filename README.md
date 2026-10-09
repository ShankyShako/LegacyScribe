# LegacyScribe

Dictation for macOS that runs on your Mac. Hold **Right ⌥**, talk, let go, and the text is pasted into whatever app you're in. Speech recognition runs on-device. An optional LLM pass cleans up the transcript or turns a spoken ramble into a structured prompt for a coding assistant.

I built it for myself, to dictate prompts to coding agents and notes all day. It's a fork of [Hex](https://github.com/kitlangton/Hex) by Kit Langton, whose Swift app is no longer developed. LegacyScribe keeps Hex's hotkey, recording and paste core and adds everything below.

## What it does

**Talk.** Hold Right ⌥ to record and release to paste. Double-tap to lock recording on, tap again to stop, Esc to cancel. Left ⌥ stays free for typing.

**Speech-to-text, on-device.** Pick an engine in Settings:

| Engine | Runs on | Word error rate on my voice | Per 10 s of audio |
|---|---|---|---|
| Cohere Transcribe 4-bit | MLX (GPU) | 5.3% | ~320 ms |
| Parakeet v3 (default) | Core ML | 8.8% | ~75 ms |
| Whisper | WhisperKit (Core ML) | not measured | not measured |

Cohere is the most accurate but needs a 1.4 GB download and ~2 GB of memory while loaded, so it loads when you press the key (hidden while you talk) and unloads once the text is out. Audio longer than ~25 s is split at the quietest point, because the model loops or drops words on long clips. Numbers are from 20 of my own clips on an M5; see [`docs/bench-results.md`](docs/bench-results.md).

**Rewrite modes.** Each dictation goes through one of three modes, switched with ⌃⌥ (hold ⌃, tap ⌥ to step through them, like ⌘-Tab):

- **Raw** pastes the transcript as heard.
- **Clean** removes filler words, false starts and repeats, and fixes punctuation.
- **Prompt** rewrites the dictation for a coding assistant. A short one becomes plain sentences. A long ramble becomes a summary, sections, one bullet per point, and the open questions at the end. Nothing is dropped and nothing is invented.

Rewrites go to any OpenAI-compatible endpoint (a local Ollama, or a router such as OmniRoute). If the primary endpoint fails or is slow, a fallback is tried, and if that fails too the raw transcript is pasted with a notice. A failed LLM never costs you a dictation. Answers cut off at the token limit, and answers far longer than what you said, are rejected rather than pasted. Each mode's instructions can be edited in Settings. API keys are kept in the Keychain.

**Code talk (Prompt mode).** Say "slash review" and `/review` reaches the assistant as a runnable command, even if every endpoint is down. "claude dot md", "dash dash verbose" and "camel case user id" come out as `CLAUDE.md`, `--verbose` and `userId`.

**Add to what's already there (Prompt mode).** If the text box you're dictating into already holds a draft, the app reads it through Accessibility and asks the model to merge the new dictation into it. "Add cheesecake" extends the list in the box instead of pasting a second prompt. If the merge would lose existing lines, or the box changed while the model worked, the transcript is pasted at the cursor instead.

**Learning from what you send.** When you press Enter after a dictation, the app keeps the version you actually sent. Those heard/sent pairs drive vocabulary suggestions (on request, from the Practice tab) and are kept as fine-tuning data.

**Read-aloud practice.** 280 sentences that cover all 39 English sounds and 881 sound pairs, plus my own jargon. Practice runs in sets of up to 10 that fill the gaps you haven't recorded yet. Each take is trimmed, saved as 16-bit audio with its text, and scored, and the folder doubles as a benchmark fixture.

The indicator turns blue while transcribing and purple while rewriting, and a small label shows mode changes and fallbacks.

## Requirements

Apple Silicon, macOS 26 or later, Xcode 26. MLX needs the Metal toolchain once per machine:

```bash
xcodebuild -downloadComponent MetalToolchain
```

## Build

```bash
cp Local.xcconfig.example Local.xcconfig   # set your team and signing identity; without it the app is signed ad hoc
open Hex.xcodeproj                         # scheme "Hex" builds "LegacyScribe Debug.app"
```

Internal names still say Hex (`Hex/` target, `HexCore` package); the app itself is LegacyScribe.

On first launch, grant Microphone, Accessibility and Input Monitoring in System Settings → Privacy & Security. Sign every build with the same identity, or macOS forgets those grants.

`tools/package-pkg.sh` builds a Release app and writes an installer package to `~/Downloads`. It isn't signed with a Developer ID, so it installs cleanly only on the Mac that built it.

## Tests

```bash
cd HexCore && swift test        # hotkeys, rewrite chain, prompts, practice picker, …
xcodebuild test -scheme Hex -skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO
```

## Data

History, audio, models and practice recordings live in `~/Library/Application Support/LegacyScribe/`. Apart from model downloads, the only thing that leaves the Mac is text sent to the rewrite endpoints you configure.

## Benchmarks

`tools/lsbench` measures engine latency, peak memory and word error rate on a folder of clips, using the same model files as the app. See [`tools/lsbench/README.md`](tools/lsbench/README.md).

## License

MIT. Hex is © Kit Langton; see [`LICENSE`](LICENSE) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for the libraries it uses.
