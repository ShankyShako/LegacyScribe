import Foundation
@testable import HexCore
import Testing

struct SentEditExtractorTests {
	@Test
	func emptyFieldGivesTheWholeFinalText() {
		#expect(SentEditExtractor.editedSegment(before: "", afterPaste: "Fix the bug.", final: "Fix the login bug.") == "Fix the login bug.")
	}

	@Test
	func surroundingTextIsCutAway() {
		let before = "Hi team,\n\nThanks"
		let after = "Hi team,\nShip it today.\nThanks"
		let final = "Hi team,\nShip it tomorrow instead.\nThanks"
		#expect(SentEditExtractor.editedSegment(before: before, afterPaste: after, final: final) == "Ship it tomorrow instead.")
	}

	@Test
	func unchangedPasteIsKept() {
		#expect(SentEditExtractor.editedSegment(before: "> ", afterPaste: "> hello", final: "> hello") == "hello")
	}

	@Test
	func editsOutsideThePasteGiveNil() {
		#expect(SentEditExtractor.editedSegment(before: "Dear Bob, ", afterPaste: "Dear Bob, see you", final: "Dear Rob, see you") == nil)
	}

	@Test
	func aPasteThatNeverLandedGivesNil() {
		#expect(SentEditExtractor.editedSegment(before: "abc", afterPaste: "abc", final: "abcd") == nil)
	}

	@Test
	func deletingEverythingGivesNil() {
		#expect(SentEditExtractor.editedSegment(before: "", afterPaste: "hello", final: "") == nil)
	}

	@Test
	func pendingEditBuildsTheRecord() throws {
		let pending = PendingSentEdit(
			startedAt: Date(timeIntervalSince1970: 0),
			transcriptID: nil,
			bundleID: "com.example.chat",
			appName: "Chat",
			mode: .prompt,
			recognized: "um fix the bug",
			pasted: "Fix the bug.",
			fieldBefore: "",
			fieldAfterPaste: "Fix the bug."
		)
		let edit = try #require(pending.sentEdit(finalField: "Fix the login bug.", at: Date(timeIntervalSince1970: 60)))
		#expect(edit.sent == "Fix the login bug.")
		#expect(edit.wasEdited)
		#expect(!pending.isExpired(at: Date(timeIntervalSince1970: 60)))
		#expect(pending.isExpired(at: Date(timeIntervalSince1970: 16 * 60)))
	}
}
