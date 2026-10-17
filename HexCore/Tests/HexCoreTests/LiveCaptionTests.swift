import Foundation
import Testing
@testable import HexCore

struct LiveCaptionTests {
	private func volatile(_ text: String, _ start: Double = 0, _ end: Double = 1) -> CaptionResult {
		CaptionResult(isFinal: false, text: text, start: start, end: end)
	}
	private func final(_ text: String, _ start: Double = 0, _ end: Double = 1) -> CaptionResult {
		CaptionResult(isFinal: true, text: text, start: start, end: end)
	}

	@Test
	func finalPlusVolatileShowsBothAndDimsTheLastWord() {
		var caption = LiveCaption()
		caption.apply(final("Can you", 0, 1))
		caption.apply(volatile("move the", 1, 2))
		#expect(caption.display.words == ["Can", "you", "move", "the"])
		#expect(caption.display.text == "Can you move the")
		#expect(caption.display.dimLast)
	}

	@Test
	func aLaterVolatileReplacesTheEarlierOne() {
		var caption = LiveCaption()
		caption.apply(final("Can you", 0, 1))
		caption.apply(volatile("move the", 1, 2))
		caption.apply(volatile("move the poster", 1, 2.4))
		#expect(caption.display.text == "Can you move the poster")
		#expect(caption.display.dimLast)
	}

	@Test
	func aFinalCoveringTheVolatileClearsIt() {
		var caption = LiveCaption()
		caption.apply(volatile("move the poster", 1, 2.4))
		caption.apply(final("Move the poster.", 1, 2.5))
		#expect(caption.display.text == "Move the poster.")
		#expect(!caption.display.dimLast)
	}

	@Test
	func aFinalEndingBeforeTheVolatileStartsKeepsIt() {
		var caption = LiveCaption()
		caption.apply(volatile("later words", 3, 4))
		caption.apply(final("Earlier.", 0, 2))
		#expect(caption.display.text == "Earlier. later words")
		#expect(caption.display.dimLast)
	}

	@Test
	func onlyTheLastEightyWordsAreShown() {
		var caption = LiveCaption()
		let words = (1...100).map { "w\($0)" }
		caption.apply(final(words.joined(separator: " "), 0, 30))
		#expect(caption.display.words.count == LiveCaption.tailWords)
		#expect(caption.display.words.first == "w21")
		#expect(caption.display.words.last == "w100")
		#expect(!caption.display.dimLast)
	}

	@Test
	func theTailCapCountsVolatileWordsToo() {
		var caption = LiveCaption()
		caption.apply(final((1...79).map { "f\($0)" }.joined(separator: " "), 0, 10))
		caption.apply(volatile("a b c", 10, 11))
		#expect(caption.display.words.count == 80)
		#expect(caption.display.words.suffix(3) == ["a", "b", "c"])
		#expect(caption.display.words.first == "f3")
	}

	@Test
	func emptyAndWhitespaceTextsCountAsEmpty() {
		var caption = LiveCaption()
		#expect(caption.display.isEmpty)
		caption.apply(final("Hello there", 0, 1))
		caption.apply(volatile("   ", 1, 2))
		#expect(caption.display.text == "Hello there")
		#expect(!caption.display.dimLast)
		caption.apply(final("  \n ", 1, 2))
		#expect(caption.display.words == ["Hello", "there"])
	}
}
