# Paste reliability matrix

Re-run at the end of every phase. For each app, dictate one short sentence into a text field with Right ⌥.

The row passes when all of these hold:
- **pasted**: the text appears exactly once, at the cursor
- **clipboard restored**: copy a marker string (e.g. `MARKER-123`) before dictating; ⌘V after dictating still pastes the marker
- **latency**: the menu bar row "Last: … ms" stays under 1 s for a short sentence with Parakeet

| App | Kind | Pasted | Clipboard restored | Latency (ms) | Notes |
|---|---|---|---|---|---|
| Notes | AppKit | | | | |
| Messages | AppKit | | | | |
| Xcode (editor) | AppKit | | | | |
| Safari (textarea) | WebKit | | | | |
| Chrome (textarea) | Chromium | | | | |
| Arc | Chromium | | | | |
| VS Code | Electron | | | | |
| Cursor | Electron | | | | |
| Slack | Electron | | | | |
| Discord | Electron | | | | |
| Terminal | AppKit | | | | |
| iTerm2 | AppKit | | | | |
| Ghostty | AppKit/Metal | | | | |
| Password field (Safari login) | Secure input | must **not** paste | | | |

Record failures with the app version and what happened (nothing pasted, pasted twice, clipboard lost).
