@testable import HexCore
import Testing

struct PracticeGradeTests {
	@Test
	func formattingIsNotAnError() {
		let grade = PracticeGrade.grade(
			script: "We need to update to version 2.4.1 of the SDK, uh, in SwiftUI.",
			heard: "We need to update to version two point four point one of the SDK in Swift UI"
		)
		#expect(grade.differences.isEmpty)
		#expect(grade.heard == 1)
	}

	@Test
	func aWordBothFamiliesHeardIsPutDownToTheReader() {
		// From the user's recordings: every engine heard "equitable" and "building".
		let script = "I think the SwiftUI view is rebuilding too often because we're not using equatable properly."
		let cohere = "I think the SwiftUI view is building too often because we're not using equitable properly."
		let parakeet = "I think the Swift UI view is building too often because we're not using equitable properly."
		let grade = PracticeGrade.grade(script: script, heard: cohere, otherFamily: parakeet)
		#expect(grade.differences.map(\.kind) == [.saidDifferently, .saidDifferently])
		#expect(grade.heard == 1)
		#expect(grade.literal < 0.95)
		#expect(grade.passes)
	}

	@Test
	func withoutASecondEngineEveryDifferenceCounts() {
		let grade = PracticeGrade.grade(script: "Harbor seals barked while lounging on docks.", heard: "Harbor seals sparked while lounging on docks.")
		#expect(grade.differences == [.init(expected: "barked", heard: "sparked", kind: .misheard)])
		#expect(!grade.passes)
	}

	@Test
	func aDisagreementStaysTheEnginesFault() {
		let grade = PracticeGrade.grade(
			script: "Harbor seals barked while lounging on docks.",
			heard: "Harbor seals sparked while lounging on docks.",
			otherFamily: "Harbor seals barked while lounging on docks."
		)
		#expect(grade.misheardCount == 1)
	}

	@Test
	func jargonTermsAreNewWords() {
		let grade = PracticeGrade.grade(
			script: "Keep the transcripts synced with Syncthing.",
			heard: "Keep the transcripts synced with Synsync.",
			terms: ["Syncthing"]
		)
		#expect(grade.differences.map(\.kind) == [.newWord])
		#expect(grade.passes)
	}

	@Test
	func extraAndMissingWordsAreAnchoredSoTheyCanBeMatched() {
		// All four engines heard "make mornings feel harder".
		let grade = PracticeGrade.grade(
			script: "King-sized beds make mornings harder.",
			heard: "King sized beds make mornings feel harder.",
			otherFamily: "King-sized beds make mornings feel harder."
		)
		#expect(grade.differences == [.init(expected: nil, heard: "feel", kind: .saidDifferently)])
	}

	@Test
	func numbersAreSpelledOut() {
		#expect(PracticeGrade.normalize("port 20128 at 3:15") == ["port", "two", "zero", "one", "two", "eight", "at", "three", "fifteen"])
		#expect(PracticeGrade.normalize("in 2026, 42%") == ["in", "twenty", "twenty", "six", "forty", "two", "percent"])
	}
}

struct PracticeGradeSummaryTests {
	@Test
	func summarizesRecordedLines() {
		func recording(_ id: String, _ text: String, heard: String?, second: String?) -> PracticeRecording {
			var recording = PracticeRecording(
				lineID: id, text: text, audioFileName: "\(id).wav", recordedAt: .distantPast, duration: 2,
				recognized: heard, engine: "cohere", wordErrorRate: nil
			)
			recording.secondOpinion = second
			return recording
		}
		let log = PracticeLog(recordings: [
			"a": recording("a", "Use equatable here.", heard: "Use equitable here.", second: "Use equitable here."),
			"b": recording("b", "Harbor seals barked.", heard: "Harbor seals sparked.", second: "Harbor seals barked."),
			"c": recording("c", "Not transcribed.", heard: nil, second: nil),
		])
		let summary = log.gradeSummary()
		#expect(summary.lines.count == 2)
		#expect(summary.words == 6)
		#expect(summary.misheard == 1)
		#expect(summary.passing == 1)
		#expect(summary.belowMark.map(\.id) == ["b"])
		#expect(summary.saidDifferently.map(\.heard) == ["equitable"])
	}
}
