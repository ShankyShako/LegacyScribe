# Paste reliability matrix

Re-run at the end of every phase. For each app, dictate one short sentence into a text field with Right ⌥.

The row passes when all of these hold:
- **pasted**: the text appears exactly once, at the cursor
- **clipboard restored**: copy a marker string (e.g. `MARKER-123`) before dictating; ⌘V after dictating still pastes the marker
- **latency**: the History window shows each dictation's key-release-to-paste time in ms (hover for the stage breakdown); it stays under 1 s for a short sentence with Parakeet in Raw mode

| App | Kind | Pasted | Clipboard restored | Latency (ms) | Notes |
|---|---|---|---|---|---|
| Notes | AppKit | yes | | | Got: "The camel walked shortly." (2026-10-06) |
| Messages | AppKit | yes | | | Got: "I hate you." (2026-10-06) |
| Xcode (editor) | AppKit | yes | | | Got: "Semicolon twelve." (2026-10-06) |
| Safari (textarea) | WebKit | | | | |
| Chrome (textarea) | Chromium | | | | |
| Arc | Chromium | | | | |
| VS Code | Electron | yes | | | Got: "Username of the student." (2026-10-06) |
| Cursor | Electron | | | | |
| Slack | Electron | | | | |
| Discord | Electron | yes | | | Got: "Sir, yes, sir." (2026-10-06) |
| Terminal | AppKit | yes | | | Got: "Python run H Garma." (2026-10-06) |
| iTerm2 | AppKit | | | | |
| Ghostty | AppKit/Metal | | | | |
| Password field (Safari login) | Secure input | must **not** paste | | | |

Record failures with the app version and what happened (nothing pasted, pasted twice, clipboard lost).
