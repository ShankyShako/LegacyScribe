import Foundation
@testable import HexCore
import Testing

struct ContextTermsTests {
	@Test
	func picksNamesAndIdentifiersButNotOrdinaryWords() {
		let text = """
		We moved the store to GRDB last week. The SwiftUI view reads from it, and Syncthing keeps the \
		folder synced with the Linux box. See CLAUDE.md and ping @genova about the M5 numbers.
		"""
		let terms = ContextTerms.extract(from: text)
		for expected in ["GRDB", "SwiftUI", "Syncthing", "Linux", "CLAUDE.md", "@genova", "M5"] {
			#expect(terms.contains(expected), "missing \(expected) in \(terms)")
		}
		for unexpected in ["We", "The", "See", "store", "folder", "week"] {
			#expect(!terms.contains(unexpected), "unexpected \(unexpected) in \(terms)")
		}
	}

	@Test
	func joinsAdjacentCapitalizedWordsIntoOneName() {
		let terms = ContextTerms.extract(from: "I opened it in Visual Studio Code and then in Claude Code.")
		#expect(terms.contains("Visual Studio Code"))
		#expect(terms.contains("Claude Code"))
		#expect(!terms.contains("I"))
	}

	@Test
	func sentenceAndListStartsAreNotNames() {
		let text = "Fences mark boundaries.\n- Kitchens are small\n1. Gardens grow\n## Notes\nSome text: Plain words"
		let terms = ContextTerms.extract(from: text)
		#expect(terms.isEmpty, "\(terms)")
	}

	@Test
	func stripsPossessivesAndKeepsSlashCommandsButNotPaths() {
		let terms = ContextTerms.extract(from: "Use GRDB's migrations, run /unslop on it, not /Users/me/file and not and/or.")
		#expect(terms.contains("GRDB"))
		#expect(terms.contains("/unslop"))
		#expect(!terms.contains("/Users"))
		#expect(!terms.contains("/or"))
	}

	@Test
	func mostUsedFirstThenClosestToTheCursor() {
		let text = "talk to Alice here. talk to Bob there. talk to Bob again. and Carol is far away from this"
		let cursor = (text as NSString).range(of: "Carol").location
		let terms = ContextTerms.extract(from: text, cursorUTF16: cursor)
		#expect(terms.first == "Bob")
		#expect(terms.firstIndex(of: "Carol")! < terms.firstIndex(of: "Alice")!)
	}

	@Test
	func readsOnlyAroundTheCursor() {
		let far = String(repeating: "filler ", count: 1000) // 7,000 characters
		let text = "Faraway is here, " + far + "and Nearby is at the cursor."
		let terms = ContextTerms.extract(from: text, cursorUTF16: (text as NSString).length)
		#expect(terms == ["Nearby"])
	}

	@Test
	func mergesSpellingsCaseInsensitively() {
		let terms = ContextTerms.extract(from: "use OmniRoute, then omniRoute, then OmniRoute again")
		#expect(terms.filter { $0.lowercased() == "omniroute" } == ["OmniRoute"])
	}

	@Test
	func cursorOffsetsAreUTF16() {
		let text = "emoji 🎉🎉 then Zed"
		let cursor = (text as NSString).length
		let (_, offset) = ContextTerms.excerpt(text, cursorUTF16: cursor)
		#expect(offset == text.count)
		#expect(ContextTerms.extract(from: text, cursorUTF16: 9_999) == ["Zed"])
	}
}

struct CorrectionTermsTests {
	func edit(_ pasted: String, _ sent: String) -> SentEdit {
		SentEdit(
			timestamp: Date(), transcriptID: nil, bundleID: "x", appName: nil, mode: .clean,
			recognized: pasted, pasted: pasted, sent: sent
		)
	}

	@Test
	func keepsSpellingFixes() {
		#expect(CorrectionTerms.fixes(pasted: "use `/slop` to write it", sent: "use /unslop to write it") == ["/unslop"])
		#expect(CorrectionTerms.fixes(pasted: "not using equitable properly", sent: "not using equatable properly") == ["equatable"])
		#expect(CorrectionTerms.fixes(pasted: "push it to github today", sent: "push it to GitHub today") == ["GitHub"])
		#expect(CorrectionTerms.fixes(pasted: "keep it on tail scale", sent: "keep it on Tailscale") == ["Tailscale"])
	}

	@Test
	func skipsContentEditsReordersAndDecapitalizing() {
		#expect(CorrectionTerms.fixes(pasted: "aliens catching my phone", sent: "aliens catching my laptop").isEmpty)
		#expect(CorrectionTerms.fixes(pasted: "Let's move forward with this building.", sent: "move forward with building this").isEmpty)
		#expect(CorrectionTerms.fixes(pasted: "The plan", sent: "the plan").isEmpty)
		#expect(CorrectionTerms.fixes(pasted: "it take time for the app", sent: "it takes time for the app's").isEmpty)
	}

	@Test
	func newestEditsFirstWithoutRepeats() {
		let edits = [
			edit("ask olama", "ask Ollama"),
			edit("same text", "same text"),
			edit("ask olama now", "ask Ollama now"),
			edit("use swift ui", "use SwiftUI"),
		]
		#expect(CorrectionTerms.extract(from: edits) == ["SwiftUI", "Ollama"])
	}

	@Test
	func plainWordFixesNeedTwoEdits() {
		let once = [edit("not using equitable", "not using equatable"), edit("it makes the icon", "it takes the icon")]
		#expect(CorrectionTerms.extract(from: once).isEmpty)
		let twice = once + [edit("make it equitable", "make it equatable")]
		#expect(CorrectionTerms.extract(from: twice) == ["equatable"])
	}
}

struct BiasingContextTests {
	@Test
	func mergesInPriorityOrderWithoutRepeats() {
		let context = BiasingContext(
			vocabulary: [" OmniRoute ", "", "TCA"],
			corrections: ["tca", "Ollama"],
			nearby: ["ollama", "Syncthing", "GRDB"]
		)
		#expect(context.vocabulary == ["OmniRoute", "TCA"])
		#expect(context.exactTerms == ["OmniRoute", "TCA", "Ollama"])
		#expect(context.nearbyOnly == ["Syncthing", "GRDB"])
		#expect(context.terms(limit: 4) == ["OmniRoute", "TCA", "Ollama", "Syncthing"])
		#expect(BiasingContext.empty.isEmpty)
	}

	@Test
	func buildReadsEverySource() {
		let context = BiasingContext.build(
			vocabulary: ["Hex"],
			sentEdits: [SentEdit(
				timestamp: Date(), transcriptID: nil, bundleID: nil, appName: nil, mode: nil,
				recognized: "", pasted: "on tail scale", sent: "on Tailscale"
			)],
			field: (text: "notes about Syncthing", cursor: nil)
		)
		#expect(context == BiasingContext(vocabulary: ["Hex"], corrections: ["Tailscale"], nearby: ["Syncthing"]))
	}
}
