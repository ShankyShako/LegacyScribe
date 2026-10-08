Write 90 read-aloud sentences that sound exactly like ONE specific person dictating to an AI coding assistant. They will be recorded in that person's voice to fine-tune a speech-recognition model, so every sentence must be something they would really say, read naturally in one breath or two.

Who they are: a developer on a Mac who builds a menu-bar dictation app (Swift, SwiftUI, TCA reducers, Xcode) and runs a model router called OmniRoute on a home server reached over Tailscale. They talk to Claude Code and T3 Code all day, ramble a bit, hedge, think out loud, and ask questions.

Real examples of how they talk (match this voice, do not copy these):
- "I want to add a whole section in the settings, not the settings itself but a tab on the left side called Practice."
- "Should we add an animation when changing modes? I can see the red circle pop up at the top of the screen, but what else can we do?"
- "Use the control option key to switch modes live while I'm talking, instead of needing separate prompts."
- "Once I press enter, that's the version I'm happy with, and I want the app to keep that in mind."

Rules:
- 12 to 30 words each. Mix requests, questions, complaints about bugs, thinking out loud, and short status updates.
- Use these terms naturally and correctly, each at least twice across the set: SwiftUI, Xcode, GitHub, Tailscale, OmniRoute, Syncthing, Groq, Ollama, Parakeet, Cohere, Whisper, MLX, Apple Silicon, macOS, TCA reducer, Keychain, Accessibility, JSON, API, LLM, CLI, SQLite, GRDB, TypeScript, Electron, Claude Code, T3 Code, menu bar, hotkey, transcript, pull request, commit, branch.
- 20 sentences contain spoken code notation written as words exactly as said, used the way a person really would: "run slash handoff", "slash pick up", "read claude dot md", "dot claude slash handoff dot md", "look at at readme dot md", "pass dash dash verbose", "rename it to camel case user name", "snake case max retries", "open hex settings dot json".
- 15 sentences contain numbers written as a clean transcript shows them (digits): versions (2.4.1), times (3:15 pm), durations (30 seconds, 2.6 seconds), sizes (24 GB, 1.4 GB), ports (20128), dates (October 8th), percentages (5.3%).
- 10 sentences start with fillers or false starts written verbatim: "Um, so, actually...", "Okay wait, no,...", "Uh, I think...".
- Include acronyms read as letters written with spaces when spelled out loud (U R L, S Q L), and homophones in context (their/there, to/too, write/right).
- No two sentences may share the same opening three words.

Write each sentence the way a perfect transcript of it would look. Output ONLY JSON lines, no prose, no code fence:
{"group": "detail", "text": "..."}
