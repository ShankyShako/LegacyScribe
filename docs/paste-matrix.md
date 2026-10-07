# Paste reliability matrix

Re-run at the end of every phase. For each app, dictate one short sentence into a text field with Right ⌥.

The row passes when all of these hold:
- **pasted**: the text appears exactly once, at the cursor
- **clipboard restored**: copy a marker string (e.g. `MARKER-123`) before dictating; ⌘V after dictating still pastes the marker
- **latency**: the History window shows each dictation's key-release-to-paste time in ms (hover for the stage breakdown); it stays under 1 s for a short sentence with Parakeet in Raw mode

| App | Kind | Pasted | Clipboard restored | Latency (ms) | Notes |
|---|---|---|---|---|---|
| Notes | AppKit | The camel is picking its pace promptly. | | 803 | Got: "The camel walked shortly." (2026-10-06) |
| Messages | AppKit | I have to try out that new cupcake treehouse spot down in the park. | | 854 | Got: "I hate you." (2026-10-06) |
| Xcode (editor) | AppKit | Semicolon sixteen. | | 1401 | Got: "Semicolon twelve." (2026-10-06) |
| Safari (textarea) | WebKit | | | | |
| Chrome (textarea) | Chromium | | | | |
| Arc | Chromium | | | | |
| VS Code | Electron | Username of the student. No period. | | 1054 | Got: "Username of the student." (2026-10-06) |
| Cursor | Electron | | | | |
| Slack | Electron | | | | |
| Discord | Electron | Yo, we need to talk about the new Mario Bros. game that came out recently. You playing? | | 849 | |
| Terminal | AppKit | Python compat DB.DATO3YCSKRO.GZ.SHA256 | | 1127 | Got: "Python run H Garma." (2026-10-06) |
| iTerm2 | AppKit | | | | |
| Ghostty | AppKit/Metal | | | | |
| Password field (Safari login) | Secure input | must **not** paste | | | |

Record failures with the app version and what happened (nothing pasted, pasted twice, clipboard lost).
