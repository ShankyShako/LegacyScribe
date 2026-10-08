Write read-aloud practice sentences for calibrating a speech-recognition model to one person's voice (an English speaker on macOS who dictates to coding assistants all day). The recordings plus the exact sentence text become fine-tuning data, so the sentences must be easy to read aloud naturally, unambiguous to pronounce, and original (do not copy the Harvard sentences, TIMIT, CMU Arctic or any published list).

Produce TWO groups, 220 sentences in total.

GROUP "general" (140 sentences): phonetically rich everyday English.
- 6 to 14 words each, one sentence each, natural and varied in topic (home, travel, food, weather, work, nature, people, objects).
- Together they must use every English sound many times, especially the rare ones: the "zh" in measure/beige/vision, "oy" in choice, voiced "th" (this, other) and unvoiced "th" (thick, both), "ng" (sing), "ch", "j" (judge), "sh", "w"/"wh", "y" (yes), "ur" (bird), "aw" (thought), "ow" (house), "oo" vs "u" (food, foot), initial and final consonant clusters (strengths, splashed, twelfths, scripts), syllabic l/n (bottle, button).
- Mix statements, questions, exclamations and short lists; vary rhythm and stress.

GROUP "detail" (80 sentences): the fine detail of how this person actually dictates. Each sentence 8 to 25 words.
- Requests to a coding assistant, in a natural spoken voice ("Can you refactor...", "I want the settings window to...").
- Technical names: SwiftUI, Xcode, GitHub, Tailscale, OmniRoute, Syncthing, Groq, Ollama, Parakeet, Cohere, Whisper, MLX, Apple Silicon, macOS, TCA reducer, Keychain, Accessibility, JSON, API, LLM, CLI, SQLite, GRDB, TypeScript, Electron, Claude Code.
- Spoken code notation, written as words exactly as said: "slash handoff", "slash pick up", "claude dot md", "dot claude slash handoff dot md", "at readme dot md", "dash dash verbose", "camel case user name", "snake case max retries".
- Numbers, versions, times, dates and units written the way a clean transcript shows them (digits): "version 2.4.1", "at 3:15 pm", "30 seconds", "October 8th", "24 GB", "port 20128", "2.6 seconds".
- Acronyms spelled out (U R L, S Q L), homophones in context (their/there, to/too, write/right), names of people and places, questions, hedges ("maybe", "I'm not sure"), a few long multi-clause sentences of 20 to 25 words, and some that start with fillers or false starts written verbatim ("Um, so, actually...").

Write each sentence the way a perfect transcript of it would look: normal spelling and punctuation, digits for numbers, code notation in words.

Output ONLY JSON lines, one object per line, no prose, no code fence:
{"group": "general", "text": "..."}
{"group": "detail", "text": "..."}
