import Foundation
@testable import HexCore
import Testing

struct FieldMergeTests {
	let list = """
	## Dessert ideas
	- Tiramisu
	- Lemon tart
	- Brownies
	"""

	@Test
	func mergesOnlyIntoUsableFields() {
		#expect(FieldMerge.existingText("  - Tiramisu\n", bundleID: "com.example.chat") == "- Tiramisu")
		#expect(FieldMerge.existingText("   \n", bundleID: "com.example.chat") == nil)
		#expect(FieldMerge.existingText(nil, bundleID: "com.example.chat") == nil)
		#expect(FieldMerge.existingText("$ ls", bundleID: "com.apple.Terminal") == nil)
		#expect(FieldMerge.existingText(String(repeating: "a", count: 6001), bundleID: "com.example.chat") == nil)
		#expect(FieldMerge.existingText("x", bundleID: nil) == nil)
	}

	@Test
	func aMergeThatKeepsTheListPasses() {
		#expect(FieldMerge.rejection(of: list + "\n- Cheesecake", existing: list) == nil)
	}

	@Test
	func aMergeThatDropsTheListIsRejected() {
		#expect(FieldMerge.rejection(of: "- Cheesecake", existing: list) != nil)
		#expect(RewriteChain.rejection(of: "- Cheesecake", transcript: "add cheesecake", existingText: list) != nil)
	}

	@Test
	func oneEditedLineIsAllowed() {
		let merged = list.replacingOccurrences(of: "- Brownies", with: "- Fudge brownies") + "\n- Cheesecake"
		#expect(FieldMerge.rejection(of: merged, existing: list) == nil)
	}

	@Test
	func aOneLineFieldMayBeRewrittenWhole() {
		#expect(FieldMerge.rejection(of: "Fix the signup bug.", existing: "Fix the login bug.") == nil)
	}

	@Test
	func theMergedLengthBudgetCountsTheExistingText() {
		let longExisting = String(repeating: "word ", count: 400)
		#expect(RewriteChain.rejection(of: longExisting + " more", transcript: "more", existingText: longExisting) == nil)
	}

	@Test
	func promptModeSendsTheExistingText() throws {
		let messages = try #require(RewritePromptBuilder.messages(mode: .prompt, transcript: "add cheesecake", existingText: list))
		#expect(messages[0].content.contains("Merge:"))
		#expect(messages[1].content.hasPrefix("<existing>\n## Dessert ideas"))
		#expect(messages[1].content.hasSuffix("<dictation>\nadd cheesecake\n</dictation>"))
		let clean = try #require(RewritePromptBuilder.messages(mode: .clean, transcript: "x", existingText: list))
		#expect(!clean[0].content.contains("Merge:"))
		#expect(clean[1].content == "<dictation>\nx\n</dictation>")
	}
}
