@testable import HexCore
import Testing

struct NotesSentencesTests {
	@Test func splitsAtSentenceEnds() {
		#expect(NotesSentences.split("a. b? c!") == ["a.", "b?", "c!"])
	}

	@Test func aDecimalPointIsNotAnEnd() {
		#expect(NotesSentences.split("3.5 percent is fine.") == ["3.5 percent is fine."])
	}

	@Test func aClosingQuoteStaysWithItsSentence() {
		#expect(NotesSentences.split("Yes.\"  Then no") == ["Yes.\"", "Then no"])
		#expect(NotesSentences.split("He said (maybe.) Then left.") == ["He said (maybe.)", "Then left."])
	}

	@Test func textWithoutPunctuationIsOneSentence() {
		#expect(NotesSentences.split("no punctuation here") == ["no punctuation here"])
	}

	@Test func emptyTextHasNoSentences() {
		#expect(NotesSentences.split("") == [])
		#expect(NotesSentences.split("  \n ") == [])
	}

	@Test func aRunOfTerminatorsIsOneEnd() {
		#expect(NotesSentences.split("Really?! Yes... Fine.") == ["Really?!", "Yes...", "Fine."])
	}

	@Test func abbreviationsSplitToo() {
		#expect(NotesSentences.split("Dr. Lee agrees.") == ["Dr.", "Lee agrees."])
	}
}
