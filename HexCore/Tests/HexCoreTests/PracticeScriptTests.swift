import Foundation
@testable import HexCore
import Testing

struct PracticeScriptTests {
	let script = PracticeScript(lines: [
		.init(id: "p001", text: "One.", stage: .sounds, soundsCovered: 20, pairsCoveredPercent: 5),
		.init(id: "p002", text: "Two.", stage: .sounds, soundsCovered: 39, pairsCoveredPercent: 9),
		.init(id: "p003", text: "Three.", stage: .pairs, soundsCovered: 39, pairsCoveredPercent: 14),
	])

	func recording(_ id: String, rate: Double? = 0, text: String = "a b c d") -> PracticeRecording {
		.init(lineID: id, text: text, audioFileName: "\(id).wav", recordedAt: .now, duration: 3, recognized: "x", engine: "e", wordErrorRate: rate)
	}

	@Test
	func resumesAtTheFirstLineNotDoneOrSkipped() {
		var log = PracticeLog()
		#expect(log.nextLine(in: script)?.id == "p001")
		log.recordings["p001"] = recording("p001")
		log.skipped = ["p002"]
		#expect(log.nextLine(in: script)?.id == "p003")
		#expect(log.coverage(in: script)?.soundsCovered == 20)
		log.recordings["p003"] = recording("p003")
		#expect(log.nextLine(in: script) == nil)
		#expect(log.coverage(in: script)?.id == "p003")
		#expect(log.recordedSeconds == 6)
	}

	@Test
	func overallRateWeighsByWords() throws {
		var log = PracticeLog()
		log.recordings["p001"] = recording("p001", rate: 0.5, text: "a b")
		log.recordings["p002"] = recording("p002", rate: 0, text: "a b c d e f")
		log.recordings["p003"] = recording("p003", rate: nil)
		#expect(try #require(log.overallWordErrorRate) == 0.125)
	}

	@Test(arguments: [
		("The quick brown fox.", "the quick brown fox", 0.0),
		("The quick brown fox.", "the quick fox", 0.25),
		("The quick brown fox.", "the quick brown box jumps", 0.5),
		("Hello there.", "", 1.0),
		("", "", 0.0),
	])
	func wordErrorRate(reference: String, hypothesis: String, expected: Double) {
		#expect(WordErrorRate.rate(reference: reference, hypothesis: hypothesis) == expected)
	}

	@Test
	func logRoundTrips() throws {
		var log = PracticeLog()
		log.recordings["p001"] = recording("p001")
		log.skipped = ["p002"]
		let decoded = try JSONDecoder().decode(PracticeLog.self, from: JSONEncoder().encode(log))
		#expect(decoded == log)
	}

	@Test
	func theBundledScriptPutsEverySoundFirst() throws {
		let url = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			.appending(path: "Hex/Resources/Data/practice_lines.json")
		let script = try JSONDecoder().decode(PracticeScript.self, from: Data(contentsOf: url))
		#expect(script.lines.count > 200)
		#expect(Set(script.lines.map(\.id)).count == script.lines.count)
		let firstFull = try #require(script.lines.firstIndex { $0.soundsCovered == PracticeScript.phonemeCount })
		#expect(firstFull < 12)
		// Stages never go backwards, so a stopped session has the coarse lines.
		let order = script.lines.map { PracticeLine.Stage.allCases.firstIndex(of: $0.stage)! }
		#expect(order == order.sorted())
		#expect(script.lines.last?.pairsCoveredPercent == 100)
	}
}
