import Foundation
@testable import HexCore
import Testing

struct SuperTriggerTests {
	@Test(arguments: [
		("Legacy, make this shorter.", "make this shorter."),
		("Legacy. Reply saying I'm in for Thursday.", "Reply saying I'm in for Thursday."),
		("Legacy! Make it friendlier.", "Make it friendlier."),
		("legacy: translate to Spanish", "translate to Spanish"),
		("Legacy… tighten this up", "tighten this up"),
		("Legacy - make it a list", "make it a list"),
		("Legacy mode, make this shorter.", "make this shorter."),
		("Legacy mode make this shorter", "make this shorter"),
		("Legacymode: fix the grammar", "fix the grammar"),
		("LEGACY, fix the typos", "fix the typos"),
		("Um, legacy, fix the typos", "fix the typos"),
		("Legacy!", ""),
		("Legacy.", ""),
		("legacy", ""),
		("Legacy mode.", ""),
		("Lucy, make this shorter.", "make this shorter."),
		("Lucy mode: fix the typos", "fix the typos"),
	])
	func findsTheInstruction(transcript: String, instruction: String) throws {
		#expect(try #require(SuperTrigger.instruction(in: transcript)) == instruction)
	}

	@Test(arguments: [
		"Legacy code is hard to change.",
		"Legacies of the old system remain.",
		"Lucy said she'd join later.",
		"Legacy-free design, thanks.",
		"That's my legacy, thanks.",
		"Legal signed off on it.",
		"",
		"Um.",
	])
	func leavesOtherDictationsAlone(transcript: String) {
		#expect(SuperTrigger.instruction(in: transcript) == nil)
	}

	@Test(arguments: [
		("", nil, false),
		("Um", nil, false),
		("Legacy", nil, false),
		("Legacy,", true, false),
		("Legacy mode", true, false),
		("Legacy, make this", true, true),
		("Legacy code", false, true),
		("Hello", false, true),
		("Legacies", false, true),
	] as [(String, Bool?, Bool)])
	func earlyVerdictWaitsForAPauseOrASecondWord(partial: String, isSuper: Bool?, settled: Bool) {
		#expect(SuperTrigger.earlyVerdict(partial) == .init(isSuper: isSuper, isSettled: settled))
	}
}

struct SuperPromptTests {
	@Test
	func anEditSendsTheSelectionAndTheInstruction() throws {
		let messages = SuperPrompt.messages(
			instruction: "make this shorter",
			request: .edit(selection: "We should probably meet sometime next week."),
			vocabulary: ["Tailscale"],
			targetAppName: "Mail"
		)
		let system = try #require(messages.first?.content)
		#expect(system.contains("pasted over the selection"))
		#expect(system.contains("in Mail"))
		#expect(system.contains("Tailscale"))
		#expect(messages.last?.content == "<selection>\nWe should probably meet sometime next week.\n</selection>\n<instruction>\nmake this shorter\n</instruction>")
	}

	@Test
	func writingSendsTheFieldAroundTheCursor() throws {
		let messages = SuperPrompt.messages(
			instruction: "reply saying I'm in for Thursday",
			request: .write(before: "Anyone up for dinner Thursday?\n", after: "")
		)
		#expect(try #require(messages.first?.content).contains("<cursor/>"))
		#expect(messages.last?.content == "<field>\nAnyone up for dinner Thursday?\n<cursor/>\n</field>\n<instruction>\nreply saying I'm in for Thursday\n</instruction>")
	}

	@Test
	func writingInAnEmptyFieldSendsOnlyTheInstruction() {
		let messages = SuperPrompt.messages(instruction: "write a haiku about rain", request: .write(before: " ", after: ""))
		#expect(messages.last?.content == "<instruction>\nwrite a haiku about rain\n</instruction>")
		#expect(messages.first?.content.contains("<field>") == false)
	}

	@Test
	func writingKeepsOnlyTheTextNearTheCursor() throws {
		let before = String(repeating: "a", count: 10_000) + "END"
		let after = "START" + String(repeating: "b", count: 10_000)
		let user = try #require(SuperPrompt.messages(instruction: "reply", request: .write(before: before, after: after)).last?.content)
		#expect(user.contains("END<cursor/>START"))
		#expect(user.count < 5_000)
	}

	@Test
	func aSelectionMustHaveTextAndFitTheCap() {
		#expect(SuperPrompt.editableSelection("  \n") == nil)
		#expect(SuperPrompt.editableSelection(String(repeating: "x", count: SuperPrompt.maxSelectionCharacters + 1)) == nil)
		#expect(SuperPrompt.editableSelection("Hello there") == "Hello there")
	}

	@Test
	func aRunawayOrEmptyAnswerIsRejected() {
		let edit = SuperRequest.edit(selection: "Short note.")
		#expect(SuperPrompt.rejection(of: "Shorter.", instruction: "make it shorter", request: edit) == nil)
		#expect(SuperPrompt.rejection(of: " ", instruction: "make it shorter", request: edit) != nil)
		#expect(SuperPrompt.rejection(of: String(repeating: "x", count: 2_000), instruction: "make it shorter", request: edit) != nil)
		let write = SuperRequest.write(before: "", after: "")
		#expect(SuperPrompt.rejection(of: String(repeating: "x", count: 1_000), instruction: "write a short reply", request: write) == nil)
	}
}
