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
| Apple Speech (macOS 26) | the system (SpeechAnalyzer) | 8.8% | ~180 ms |
| Whisper | WhisperKit (Core ML) | not measured | not measured |

Cohere is the most accurate but needs a 1.4 GB download and ~2 GB of memory while loaded, so it loads when you press the key (hidden while you talk) and unloads once the text is out. Audio longer than ~25 s is split at the quietest point, because the model loops or drops words on long clips. Apple Speech uses the model macOS installs, so it costs the app almost no memory (16 MB). Numbers are from 20 of my own clips on an M5; see [`docs/bench-results.md`](docs/bench-results.md).

**Rewrite modes.** Each dictation goes through one of three modes, switched with ⌃⌥ (hold ⌃, tap ⌥ to step through them, like ⌘-Tab). A fourth, Notes, is described below.

- **Raw** pastes the transcript as heard.
- **Clean** removes filler words, false starts and repeats, and fixes punctuation.
- **Prompt** rewrites the dictation for a coding assistant. A short one becomes plain sentences. A long ramble becomes a summary, sections, one bullet per point, and the open questions at the end. Nothing is dropped and nothing is invented.

Choose who rewrites in the **AI Rewrite** tab:

- **On this Mac.** Download a model once (Qwen3 1.7B, 4B or 8B, 1–4.6 GB) and it runs inside the app with MLX. Free and private, and it needs no account or other app. On an M5 the recommended 4B model tidies a short dictation in 0.4–1.5 s and 100 words in about 3 s.
- **A cloud AI with your own API key:** OpenAI, Anthropic, Google Gemini, Groq or OpenRouter. Paste the key and press Check connection, which picks a fast model for you. Groq rewrites a dictation in under a second.
- **Ollama, or any OpenAI-compatible server** such as OmniRoute or LM Studio.

Until one is set up, dictations are pasted as heard. If the AI fails or is slow, an optional backup AI is tried, and if that fails too the raw transcript is pasted with a notice. A failed LLM never costs you a dictation. Answers cut off at the token limit, and answers far longer than what you said, are rejected rather than pasted. Each mode's instructions can be edited in Settings. API keys are kept in the Keychain.

**Code talk (Prompt mode).** Say "slash review" and `/review` reaches the assistant as a runnable command, even if every endpoint is down. "claude dot md", "dash dash verbose" and "camel case user id" come out as `CLAUDE.md`, `--verbose` and `userId`.

**Add to what's already there (Prompt mode).** If the text box you're dictating into already holds a draft, the app reads it through Accessibility and asks the model to merge the new dictation into it. "Add cheesecake" extends the list in the box instead of pasting a second prompt. If the merge would lose existing lines, or the box changed while the model worked, the transcript is pasted at the cursor instead.

**Learning from what you send.** When you press Enter after a dictation, the app keeps the version you actually sent. Those heard/sent pairs drive vocabulary suggestions (on request, from the Practice tab) and are kept as fine-tuning data.

**Notes.** Pick Notes (⌃⌥4), tap Right ⌥ and think out loud for up to 2 hours, hands-free, then tap again. Cohere transcribes while you talk, 25 seconds at a time, and a model on your Mac (the one downloaded in AI Rewrite, or Ollama) turns the transcript into notes afterwards: topics, one bullet per point, action items and open questions. Nothing is sent off the Mac and no audio is kept. Each chunk is written to disk and committed to the transcript before its audio is deleted, so a crash or quit loses at most the last 30 seconds, and an unfinished session resumes at the next launch. Sessions are in the Notes tab, and can also be saved as Markdown to a folder such as an Obsidian vault.

**Read-aloud practice.** 280 sentences that cover all 39 English sounds and 881 sound pairs, plus my own jargon. Practice runs in sets of up to 10 that fill the gaps you haven't recorded yet. Each take is trimmed, saved as 16-bit audio with its text, and scored, and the folder doubles as a benchmark fixture. "Check my recordings" grades how much of each line the engine heard right, aiming for 95%. A second engine of a different kind listens too, so a word you read differently (both engines heard "equitable" for "equatable") doesn't count against the engine; it's listed for you to practice instead.

**Private mode.** Turn it on in the menu bar menu or Settings → General and nothing leaves the Mac: only the on-device model rewrites (other AIs are skipped and the text is pasted as heard), and there are no update checks or downloads. It's enforced underneath too: every network request the app or its libraries make fails while it's on. A lock shows on the menu bar icon and while recording.

**History.** Every dictation is kept: the text forever, the audio for 30 days by default (Settings → History → Keep Recordings), except recordings you corrected before sending, which are kept as training data. Play an entry and its words light up as they're spoken.

**Voice isolation.** For noisy places, Settings → Microphone → Voice isolation records dictation through Apple's voice processing, which keeps the voice nearest the microphone and turns down people talking around you. Set Mic Mode to Voice Isolation (the button opens it) for the strongest effect. Notes has its own switch, off by default so a meeting keeps every voice.

The indicator turns blue while transcribing and purple while rewriting, and a small label shows mode changes and fallbacks.

## Install

Apple Silicon and macOS 26 or later. In Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/ShankyShako/LegacyScribe/main/install.sh | bash
```

It downloads the latest release, checks that the app is signed by LegacyScribe's team, puts it in Applications and opens it. The app isn't signed with an Apple Developer ID yet, so a copy downloaded with a browser is blocked by macOS; if you'd rather do that, open it once, then go to System Settings → Privacy & Security and press **Open Anyway**.

## Getting started

1. Open LegacyScribe and allow Microphone, Accessibility and Input Monitoring when asked.
2. In **AI Rewrite**, press **Download** next to the recommended model, or pick a cloud AI and paste an API key.
3. Hold Right ⌥, talk, let go.

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

### Updates

Release builds check this repo's latest GitHub release once a day (Sparkle). An update found in the background shows up as a notification and an "Install Update…" item in the menu bar menu; Settings → About has a manual check and the automatic-install toggle. Debug builds don't update.

To ship one: optionally write `release-notes/<version>.md` (copy `release-notes/TEMPLATE.md`), then run `tools/release.sh <version>` (bumps the version, builds, zips, writes the signed appcast, commits and tags) and `tools/release.sh --publish <version>` (pushes and creates the GitHub release; needs `gh`). Updates are signed with an EdDSA key in the login Keychain; back it up with `generate_keys --account com.genovamongalo.LegacyScribe -x <file>`. A copy downloaded with a browser is quarantined, so the first install on another Mac needs System Settings → Privacy & Security → Open Anyway (or `install.sh`, which downloads with curl and checks the signature itself); updates after that aren't quarantined.

## Tests

```bash
cd HexCore && swift test        # hotkeys, rewrite chain, prompts, practice picker, store, …
xcodebuild test -scheme Hex -skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO
tools/notes-crashtest.py <10-min.wav>   # Notes: kill -9 at each stage, forced resets, memory
```

## Data

History, audio, models, practice recordings and notes sessions live in `~/Library/Application Support/LegacyScribe/`. History, word timings and sent edits are in `scribe.sqlite` (open it with `sqlite3`). Apart from model downloads and update checks, the only thing that leaves the Mac is text sent to the rewrite endpoints you configure, and in Private mode nothing does. [`PRIVACY.md`](PRIVACY.md) lists everything that is stored, read and sent.

## Benchmarks

`tools/lsbench` measures engine latency, peak memory and word error rate on a folder of clips, using the same model files as the app. See [`tools/lsbench/README.md`](tools/lsbench/README.md).

## License

MIT. Hex is © Kit Langton; see [`LICENSE`](LICENSE) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for the libraries it uses.
