import Foundation

/// Spoken code notation for Prompt mode: "slash handoff" → `/handoff`, "claude dot md" → `CLAUDE.md`,
/// "at claude dot md" → `@CLAUDE.md`.
///
/// A slash command at the start of a dictation is resolved here, without the LLM, so it runs even when every
/// rewrite endpoint fails and costs no round trip when nothing follows it. Mentions elsewhere in the dictation
/// are left to the LLM, which gets `instructions(slashCommands:)` with the names it should match.
public enum CodeTalk {
	/// Claude Code's own commands, matched alongside the user's skills and commands.
	public static let builtInSlashCommands = [
		"add-dir", "agents", "clear", "code-review", "compact", "config", "context", "cost", "doctor", "exit",
		"help", "hooks", "init", "login", "logout", "loop", "mcp", "memory", "model", "permissions", "plan",
		"resume", "review", "rewind", "schedule", "security-review", "simplify", "status", "usage",
	]

	/// Files and folders a coding assistant knows by name.
	public static let knownFiles = [
		"CLAUDE.md", "AGENTS.md", "README.md", ".claude/", ".claude/settings.json", ".claude/settings.local.json",
		".claude/handoff.md", ".claude/skills/", ".claude/commands/", "~/.claude/", ".mcp.json",
	]

	/// Words skipped between "slash" and the command name.
	static let fillers: Set<String> = ["um", "uh", "erm", "er"]

	/// A dictation that starts with a slash command, split into the command and what follows it.
	public struct LeadingCommand: Equatable, Sendable {
		/// e.g. "/pickup"
		public var command: String
		/// The rest of the dictation, trimmed; empty when the command was all that was said.
		public var remainder: String
	}

	/// Finds a known command at the start of `transcript`: "Slash pick up, then run the tests." →
	/// `/pickup` + "then run the tests." The name may be split into words ("hand off", "code review") and
	/// the recognizer may have written "/handoff" itself. Nil when the dictation doesn't start that way or
	/// the name isn't one of `commands`.
	public static func leadingCommand(in transcript: String, commands: [String]) -> LeadingCommand? {
		let byKey = Dictionary(
			commands.map { (key($0), $0) }.filter { !$0.0.isEmpty },
			uniquingKeysWith: { first, _ in first }
		)
		guard !byKey.isEmpty else { return nil }

		var words = wordRanges(in: transcript)
		guard let first = words.first else { return nil }
		let firstWord = transcript[first]
		if firstWord.hasPrefix("/") {
			// The recognizer wrote "/handoff" or "/hand off": treat the slash as its own word.
			if firstWord.count == 1 {
				words.removeFirst()
			} else {
				words[0] = transcript.index(after: first.lowerBound) ..< first.upperBound
			}
		} else if key(firstWord) == "slash" {
			words.removeFirst()
		} else {
			return nil
		}
		while let next = words.first, fillers.contains(key(transcript[next])) {
			words.removeFirst()
		}

		// Longest match first, so "code review" beats "code".
		for count in stride(from: min(3, words.count), through: 1, by: -1) {
			let candidate = words.prefix(count).map { key(transcript[$0]) }.joined()
			guard let command = byKey[candidate] else { continue }
			var rest = words.dropFirst(count)
			while let next = rest.first, fillers.contains(key(transcript[next])) {
				rest = rest.dropFirst()
			}
			let remainder = rest.first.map { transcript[$0.lowerBound...] } ?? ""
			return LeadingCommand(
				command: "/" + command,
				remainder: remainder.drop { $0.isPunctuation }.trimmingCharacters(in: .whitespacesAndNewlines)
			)
		}
		return nil
	}

	/// Joins a resolved command with the rewritten rest of the dictation.
	public static func join(_ command: LeadingCommand, rewrittenRemainder: String) -> String {
		let rest = rewrittenRemainder.trimmingCharacters(in: .whitespacesAndNewlines)
		return rest.isEmpty ? command.command : "\(command.command) \(rest)"
	}

	/// The Prompt-mode rules for writing spoken notation as code. `slashCommands` are names without the slash.
	public static func instructions(slashCommands: [String]) -> String {
		let commands = (slashCommands.isEmpty ? builtInSlashCommands : slashCommands).map { "/" + $0 }
		return """
		Code talk: the speaker says code notation out loud; write it as code.
		- "slash" before a command name is a slash command: "slash handoff" → /handoff. Match a near-miss or a \
		name split into words to the closest of these: \(commands.joined(separator: ", ")).
		- "dot" inside a file name is ".", "slash" inside a path is "/", and "at" before a file is "@" (a file \
		reference): "claude dot md" → CLAUDE.md, "dot claude slash handoff dot md" → .claude/handoff.md, \
		"at readme dot md" → @README.md. Known names: \(knownFiles.joined(separator: ", ")).
		- "dash dash" before a word is a flag (--verbose). "camel case", "pascal case", "snake case" or "kebab case" \
		is not written out; it joins the words after it into one identifier, up to the next pause or "and": \
		"rename it to camel case rewrite fallback count" → "rename it to rewriteFallbackCount", "snake case max \
		retries" → max_retries.
		- A spoken file name keeps its language's casing: Swift, Kotlin and C# files are named after their type \
		("transcription feature dot swift" → TranscriptionFeature.swift); Python is snake_case.
		- In running text, wrap a command, path, flag or identifier in backticks, except an @ file reference, \
		which stays bare. Only convert words that are clearly notation: "and slash or" stays "and/or" prose.
		"""
	}

	/// Skill and command names in a Claude config folder (`~/.claude`): `skills/<name>/SKILL.md` and
	/// `commands/<name>.md`, sorted and without duplicates.
	public static func slashCommands(inClaudeFolder folder: URL, fileManager: FileManager = .default) -> [String] {
		var names = Set<String>()
		let skills = folder.appendingPathComponent("skills", isDirectory: true)
		for entry in (try? fileManager.contentsOfDirectory(atPath: skills.path)) ?? [] where !entry.hasPrefix(".") {
			let skillFile = skills.appendingPathComponent(entry).appendingPathComponent("SKILL.md")
			if fileManager.fileExists(atPath: skillFile.path) {
				names.insert(entry)
			}
		}
		let commands = folder.appendingPathComponent("commands", isDirectory: true)
		for entry in (try? fileManager.contentsOfDirectory(atPath: commands.path)) ?? []
			where entry.hasSuffix(".md") && !entry.hasPrefix(".") {
			names.insert(String(entry.dropLast(3)))
		}
		return names.sorted()
	}

	/// Lowercase letters and digits only, so "Hand-off," and "handoff" compare equal.
	static func key<S: StringProtocol>(_ text: S) -> String {
		String(text.lowercased().filter { $0.isLetter || $0.isNumber })
	}

	static func wordRanges(in text: String) -> [Range<String.Index>] {
		var ranges: [Range<String.Index>] = []
		var start: String.Index?
		for index in text.indices {
			if text[index].isWhitespace {
				if let s = start { ranges.append(s ..< index) }
				start = nil
			} else if start == nil {
				start = index
			}
		}
		if let s = start { ranges.append(s ..< text.endIndex) }
		return ranges
	}
}
