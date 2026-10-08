import Foundation
@testable import HexCore
import Testing

struct CodeTalkTests {
	let commands = ["handoff", "pickup", "code-review", "review", "commit"]

	@Test(arguments: [
		("Slash handoff.", "/handoff", ""),
		("slash hand off", "/handoff", ""),
		("Slash, um, pick up, then run the tests.", "/pickup", "then run the tests."),
		("Slash code review the last commit", "/code-review", "the last commit"),
		("Slash review the last commit", "/review", "the last commit"),
		("/handoff and note the open bug", "/handoff", "and note the open bug"),
		("/ pickup", "/pickup", ""),
		("SLASH COMMIT", "/commit", ""),
		("Slash handoff, um, and note the bug.", "/handoff", "and note the bug."),
		("Slash handoff uh.", "/handoff", ""),
	])
	func resolvesALeadingCommand(transcript: String, command: String, remainder: String) throws {
		let found = try #require(CodeTalk.leadingCommand(in: transcript, commands: commands))
		#expect(found.command == command)
		#expect(found.remainder == remainder)
	}

	@Test(arguments: [
		"Slash the budget by half.",
		"Run slash handoff later.",
		"Slashing prices",
		"",
		"slash",
	])
	func leavesOtherDictationsAlone(transcript: String) {
		#expect(CodeTalk.leadingCommand(in: transcript, commands: commands) == nil)
	}

	@Test
	func noKnownCommandsMeansNoMatch() {
		#expect(CodeTalk.leadingCommand(in: "slash handoff", commands: []) == nil)
	}

	@Test
	func joinPutsTheCommandFirst() {
		let command = CodeTalk.LeadingCommand(command: "/pickup", remainder: "x")
		#expect(CodeTalk.join(command, rewrittenRemainder: " Then run the tests.\n") == "/pickup Then run the tests.")
		#expect(CodeTalk.join(command, rewrittenRemainder: "") == "/pickup")
	}

	@Test
	func findsSkillsAndCommandsInAClaudeFolder() throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codetalk-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: folder) }
		let fm = FileManager.default
		for skill in ["handoff", "animate"] {
			let dir = folder.appendingPathComponent("skills/\(skill)")
			try fm.createDirectory(at: dir, withIntermediateDirectories: true)
			try Data().write(to: dir.appendingPathComponent("SKILL.md"))
		}
		try fm.createDirectory(at: folder.appendingPathComponent("skills/synced"), withIntermediateDirectories: true)
		try fm.createDirectory(at: folder.appendingPathComponent("commands"), withIntermediateDirectories: true)
		try Data().write(to: folder.appendingPathComponent("commands/pickup.md"))
		try Data().write(to: folder.appendingPathComponent("commands/handoff.md"))
		try Data().write(to: folder.appendingPathComponent("commands/notes.txt"))

		#expect(CodeTalk.slashCommands(inClaudeFolder: folder) == ["animate", "handoff", "pickup"])
		#expect(CodeTalk.slashCommands(inClaudeFolder: folder.appendingPathComponent("missing")) == [])
	}

	@Test
	func promptModeGetsTheRulesEvenWithCustomInstructions() throws {
		let messages = try #require(RewritePromptBuilder.messages(
			mode: .prompt,
			transcript: "x",
			instructions: "Write a haiku.",
			codeTalkCommands: ["handoff"]
		))
		let system = messages[0].content
		#expect(system.hasPrefix("Write a haiku.\nCode talk:"))
		#expect(system.contains("/handoff"))
		#expect(system.contains("CLAUDE.md"))
	}

	@Test
	func otherModesAndNilCommandsSkipTheRules() throws {
		let clean = try #require(RewritePromptBuilder.messages(mode: .clean, transcript: "x", codeTalkCommands: ["handoff"]))
		#expect(!clean[0].content.contains("Code talk"))
		let off = try #require(RewritePromptBuilder.messages(mode: .prompt, transcript: "x"))
		#expect(!off[0].content.contains("Code talk"))
	}
}
