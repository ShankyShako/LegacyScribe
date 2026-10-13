# Competitor comparison (2026-10-12)

What Wispr Flow, Superwhisper, VoiceInk, Aqua Voice, Monologue, Willow and Spokenly ship, and what LegacyScribe should take from them. The adoption plan is `docs/plan.md` "P3.5". Aqua, Willow and Spokenly facts come mostly from vendor or listing pages; treat them loosely.

## Already matched or ahead

| Competitor feature | LegacyScribe |
|---|---|
| Superwhisper: Cohere Transcribe (2.17.0, Jul 2026), on-device S1-mini cleanup (2.18.0, Aug 2026) | Both since early October. Wispr Flow is still cloud-only. |
| Wispr: "Prompt Engineer" transform (May 2026) | Prompt mode, plus code talk and field merge (no competitor merges into the field) |
| Wispr: double-tap push-to-talk for hands-free (Aug 2026) | Double-tap lock |
| Wispr: dictionary auto-adds a name after you correct its spelling | `CorrectionTerms` learns from sent text, no manual correction |
| Wispr: 14-day audio playback; Superwhisper: recording retention (2.11.0) | 30-day retention, word-highlighted playback |
| Wispr Scratchpad, Superwhisper meeting mode | Notes mode (crash-tested, flat memory) |
| Monologue/VoiceInk: screen-reading context | Accessibility field read; only extracted names leave the Mac |
| Superwhisper: pause media while recording (2.8.0) | `pauseMediaOnRecord` (from Hex) |
| Replacements (Superwhisper, Wispr snippets) | `WordRemapping` (from Hex) |

## Gaps, with who has them

| Gap | Who | Notes |
|---|---|---|
| Self-correction ("meet at 2, no, make it 3" → 3) | Wispr ("Backtrack"), Willow | Our Clean prompt only says "false starts" |
| Match surrounding text when pasting mid-sentence (case, spacing, trailing period) | Superwhisper 2.8.0 "smart capitalization" | We already read field + cursor at key-down |
| Failed dictation is kept and recoverable from History | Wispr (May 2026) | We delete the audio in `handleTranscriptionError` |
| Reprocess a history entry with another mode | Superwhisper 2.8.0 | We keep audio and `rawText` |
| Undo the AI edit (restore what was heard) | Wispr "Undo AI edit" (Apr 2026) | History shows the original but can't paste it |
| Deep links to start/stop recording | Superwhisper 2.16.3 | No URL scheme |
| Clipboard context (copied ≤3 s before or during recording) | Superwhisper, VoiceInk | On our P3 optional list |
| Spoken edit of selected text | Wispr Transforms (beta, May 2026) / "Command Mode"; Superwhisper selected-text context | Pieces exist: AX read, ⌘A+paste replace |
| Per-app style or mode | Wispr Styles (personal messaging / work messaging / email), VoiceInk Power Mode (app + URL), Superwhisper app/site activation | Our P2 "Mode model" item |
| Live streaming preview | Superwhisper (Parakeet Realtime, 2.9.0), Aqua | Cohere can't stream |
| Screen OCR context | VoiceInk (Vision OCR, text only), Monologue | Needs Screen Recording permission |
| MCP/CLI access to notes or history | Wispr (Notetaker only), Monologue, Spokenly (agents call it for voice input) | — |
| Muffle other audio while recording | Superwhisper 2.19.0 | We pause media instead |

Not for us: hosted cloud sync (a sync folder is planned instead, P3.5 B6), team/admin dictionaries, bot-free meeting capture of system audio (maybe later for Notes), in-house speech models (our version is the P4.5/P5 LoRA work).

## Sources
- Wispr Flow changelog: https://wisprflow.ai/whats-new
- Wispr dictionary: https://wispr.notion.site/Dictionary-1992ebdc733481a08064efd983f19f0f
- Wispr file tagging: https://wisprflow.ai/post/file-tagging-in-cursor
- Wispr Flow 101: https://sidsaladi.substack.com/p/wispr-flow-101-the-complete-guide
- Superwhisper changelog: https://ai.superwhisper.com/changelog
- Superwhisper context: https://superwhisper.com/docs/common-issues/context
- Superwhisper Super mode: https://superwhisper.com/docs/modes/super
- VoiceInk Power Mode: https://tryvoiceink.com/docs/power-mode
- VoiceInk context awareness: https://tryvoiceink.com/docs/context-awareness
- Aqua Voice listing: https://toolquestor.com/es/tool/aqua-voice
- Monologue: https://www.monologue.to/ and https://www.getvoibe.com/resources/monologue-review/
- Willow: https://willowvoice.com/features/dictation
- Spokenly vs Willow: https://spokenly.app/comparison/willow-voice
