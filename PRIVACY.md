# Privacy

LegacyScribe is built to keep what you say on your Mac. This page lists everything it stores, everything that can leave your Mac, and how to delete it. Last updated 17 October 2026.

## The short version

- There is no account, no analytics, no crash reporting and no tracking. The developer receives nothing from your copy of the app.
- Speech recognition always runs on your Mac. So do Notes, the Speech Coach and voice recognition.
- Text leaves your Mac only if you choose a cloud AI for rewriting (OpenAI, Anthropic, Gemini, Groq, OpenRouter, or a server you name). Out of the box the rewrite runs on your Mac, or is skipped.
- **Private mode** (menu bar menu or Settings → General) blocks every network request the app and its libraries make, enforced in code, not by promise.

## What is stored on your Mac

Everything lives in `~/Library/Application Support/LegacyScribe/`, except API keys, which are in your login Keychain.

| What | Kept for | Notes |
|---|---|---|
| Dictation text (what was heard, and the rewritten text) | Until you delete it | History tab; Delete All is in its menu |
| Dictation recordings | 30 days by default (Settings → History: 7 days to forever) | A recording whose text you corrected before sending is kept, as a correction example |
| The text you actually sent after a dictation | Until you delete it | Captured when you press Enter in the app you dictated into (not in terminals). Turn off with "Remember what I send" in the Practice tab |
| Notes sessions: transcript and notes | Until you delete the session | No audio is kept: each 25-second piece is deleted once it's transcribed |
| Your voiceprint, and voices you named in Notes | Until you choose Forget (Notes → Notes settings → Speakers) | A list of 256 numbers describing a voice, made on this Mac. Not a recording, and never uploaded |
| Read-aloud practice recordings | Until you delete them | Practice tab |
| Speech Coach statistics | Until you turn the coach off and delete its data | Counts and times, worked out from your History recordings |
| Settings, downloaded models | Until you delete them | |
| API keys | Until you remove them | Keychain, never in the settings file |

To remove everything, quit LegacyScribe, delete the folder above, and remove the `com.genovamongalo.LegacyScribe` items in Keychain Access.

## What the app reads from other apps

With your permission (Accessibility), LegacyScribe reads the text box you are dictating into. It does this to:

- match the text around the cursor (lowercase mid-sentence, spacing);
- merge a Prompt-mode dictation into a draft that is already in the box;
- pick up names near the cursor so the rewrite spells them right;
- run a spoken instruction ("Legacy, …") on your selection or around the cursor;
- keep the version you sent (see above).

Terminals are skipped for all of these. Input Monitoring is used only to see the talk key and Enter; keystrokes are not recorded.

## What can leave your Mac, and when

| When | What is sent | To |
|---|---|---|
| You chose a cloud AI or a server for rewriting | The dictation's text. Depending on the features in use, also: the box's text (Prompt-mode merge), up to 3,000 characters around the cursor or your selection (spoken instructions), names found near the cursor (never the box's text), and your vocabulary list | The provider you picked, under its own privacy policy |
| You press "Check my history" in Practice | Up to ~14,000 characters of heard and sent text pairs | Your rewrite AI |
| You use research in Practice (custom servers only) | Your question | Your server |
| You download a model | A request for that model (your IP address is visible to the host) | Hugging Face |
| Daily update check (release builds) | A request for the update feed; no system profile is sent | GitHub |

Notes text never goes to a cloud AI: notes are written by a model on your Mac or by Ollama on your Mac. Audio never leaves your Mac.

In Private mode none of the rows above happen: only the on-device model rewrites, and there are no update checks or downloads.

## Questions

Open an issue at [github.com/ShankyShako/LegacyScribe/issues](https://github.com/ShankyShako/LegacyScribe/issues).
