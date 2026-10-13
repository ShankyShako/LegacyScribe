import Foundation
@testable import HexCore
import Testing

struct CTCWordAlignerTests {
	/// Vocabulary of 5 with blank = 4. Each frame strongly favours one label.
	let blank = 4
	let frame = 0.08

	func emissions(_ labels: [Int]) -> [[Float]] {
		labels.map { label in
			(0 ..< 5).map { Float(log($0 == label ? 0.9 : 0.025)) }
		}
	}

	let vocabulary: [String: [Int]] = ["a": [0], "bc": [1, 2], "d": [3], ",": []]

	func tokenize(_ word: String) -> [Int] { vocabulary[word] ?? [] }

	@Test
	func wordsGetTheFramesOfTheirTokens() throws {
		// blank blank a a blank b c blank blank blank a blank
		let logProbs = emissions([4, 4, 0, 0, 4, 1, 2, 4, 4, 4, 0, 4])
		let timings = try #require(CTCWordAligner.align(words: ["a", "bc", "a"], logProbs: logProbs, frameDuration: frame, blank: blank, tokenize: tokenize))
		#expect(timings.map(\.word) == ["a", "bc", "a"])
		#expect(timings.map { round($0.start / frame) } == [2, 5, 10])
		#expect(timings.map { round($0.end / frame) } == [4, 7, 11])
	}

	@Test
	func equalNeighboursNeedABlankBetweenThem() throws {
		// a a blank a: the second "a" can't start on frame 1, the CTC blank rule separates them.
		let logProbs = emissions([0, 0, 4, 0])
		let timings = try #require(CTCWordAligner.align(words: ["a", "a"], logProbs: logProbs, frameDuration: frame, blank: blank, tokenize: tokenize))
		#expect(timings.map { round($0.start / frame) } == [0, 3])
		#expect(timings.map { round($0.end / frame) } == [2, 4])
	}

	@Test
	func aWordWithoutTokensSitsInTheGap() throws {
		let logProbs = emissions([0, 4, 4, 3, 4])
		let timings = try #require(CTCWordAligner.align(words: ["a", ",", "d"], logProbs: logProbs, frameDuration: frame, blank: blank, tokenize: tokenize))
		#expect(timings[1].start == timings[0].end)
		#expect(timings[1].end == timings[2].start)
	}

	@Test
	func tooFewFramesGiveNil() {
		#expect(CTCWordAligner.align(words: ["bc", "a"], logProbs: emissions([1, 2]), frameDuration: frame, blank: blank, tokenize: tokenize) == nil)
		#expect(CTCWordAligner.align(words: ["a", "a"], logProbs: emissions([0, 0]), frameDuration: frame, blank: blank, tokenize: tokenize) == nil)
	}

	@Test
	func theAlignmentFollowsTheAudioNotAnEvenSplit() throws {
		// A long pause before "d": a naive even split would put "d" early.
		let logProbs = emissions([0] + Array(repeating: 4, count: 20) + [3, 4])
		let timings = try #require(CTCWordAligner.align(words: ["a", "d"], logProbs: logProbs, frameDuration: frame, blank: blank, tokenize: tokenize))
		#expect(round(timings[1].start / frame) == 21)
	}
}

struct WordMatcherTests {
	func heard(_ words: [(String, Double, Double)]) -> [SpokenWord] {
		words.map { SpokenWord(word: $0.0, start: $0.1, end: $0.2) }
	}

	@Test
	func matchingWordsTakeTheirTimingsWhateverTheCaseAndPunctuation() {
		let timed = WordMatcher.transfer(heard([("so", 0.1, 0.3), ("ship", 0.3, 0.6), ("it", 0.6, 0.8)]), onto: ["So,", "ship", "it."])
		#expect(timed.map(\.word) == ["So,", "ship", "it."])
		#expect(timed.map(\.start) == [0.1, 0.3, 0.6])
		#expect(timed.map(\.end) == [0.3, 0.6, 0.8])
	}

	@Test
	func aDisagreementStaysLocal() {
		// "three fifteen" heard, "3:15" written: the extra heard word widens its partner, later words keep theirs.
		let timed = WordMatcher.transfer(
			heard([("at", 0.0, 0.2), ("three", 0.2, 0.5), ("fifteen", 0.5, 0.9), ("again", 1.0, 1.4)]),
			onto: ["at", "3:15", "again"]
		)
		#expect(timed[1].start == 0.2)
		#expect(timed[1].end == 0.9)
		#expect(timed[2].start == 1.0)
	}

	@Test
	func aWordNobodyHeardSitsInTheGap() {
		let timed = WordMatcher.transfer(heard([("hello", 0.0, 0.4), ("world", 0.8, 1.2)]), onto: ["hello", "big", "world"])
		#expect(timed[1].start == 0.4)
		#expect(timed[1].end == 0.8)
	}

	@Test
	func theShiftNeverPassesTheEnd() {
		let timed = WordMatcher.transfer(heard([("a", 0.0, 0.05), ("b", 0.05, 0.5)]), onto: ["a", "b"], startShift: 0.08)
		#expect(timed[0].start == 0.05)
		#expect(abs(timed[1].start - 0.13) < 1e-9)
	}

	@Test
	func nothingHeardGivesNothing() {
		#expect(WordMatcher.transfer([], onto: ["a"]).isEmpty)
	}
}
