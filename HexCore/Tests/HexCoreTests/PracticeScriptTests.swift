import Foundation
@testable import HexCore
import Testing

/// Deterministic generator for picks (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
	var state: UInt64
	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		return z ^ (z >> 31)
	}
}

struct PracticeScriptTests {
	static let bundled: PracticeScript = {
		let url = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			.appending(path: "Hex/Resources/Data/practice_lines.json")
		return try! JSONDecoder().decode(PracticeScript.self, from: Data(contentsOf: url))
	}()

	func recording(_ id: String, rate: Double? = 0, text: String = "a b c d") -> PracticeRecording {
		.init(lineID: id, text: text, audioFileName: "\(id).wav", recordedAt: .now, duration: 3, recognized: "x", engine: "e", wordErrorRate: rate)
	}

	@Test
	func setsHaveTheAskedMix() {
		var rng = SeededGenerator(state: 1)
		for _ in 0 ..< 200 {
			let slots = PracticePicker.setSlots(using: &rng)
			let count = { (stage: PracticeLine.Stage) in slots.filter { $0 == stage }.count }
			#expect(slots.count <= PracticePicker.maxSetSize)
			#expect((3 ... 5).contains(count(.sounds)))
			#expect((1 ... 3).contains(count(.pairs)))
			#expect((1 ... 2).contains(count(.detail)))
			#expect(count(.extra) == 1)
		}
	}

	@Test
	func aSetSkipsRecordedAndSeenLinesAndFitsEachSlot() throws {
		let script = Self.bundled
		var log = PracticeLog()
		var rng = SeededGenerator(state: 7)
		let first = PracticePicker.pickSet(script: script, log: log, using: &rng)
		#expect((6 ... 10).contains(first.count))
		#expect(Set(first.map(\.id)).count == first.count)
		for pick in first {
			switch pick.role {
			case .detail: #expect(pick.line.stage == .detail)
			case .extra: #expect(pick.line.stage == .extra)
			case .sounds, .pairs: #expect(pick.line.stage != .detail)
			}
		}

		// Record half, see the rest: the next set shares nothing with this one.
		for (index, pick) in first.enumerated() {
			if index.isMultiple(of: 2) { log.recordings[pick.id] = recording(pick.id) }
			log.seen.insert(pick.id)
		}
		let second = PracticePicker.pickSet(script: script, log: log, using: &rng)
		#expect(Set(second.map(\.id)).isDisjoint(with: first.map(\.id)))
	}

	@Test
	func theFirstSoundLinesCoverMostSounds() {
		var rng = SeededGenerator(state: 3)
		let picks = PracticePicker.pickSet(script: Self.bundled, log: PracticeLog(), using: &rng)
		let sounds = PracticeCoverage(picks.filter { $0.role == .sounds }.map(\.line))
		#expect(sounds.soundsCovered >= 30)
	}

	@Test
	func shownLinesComeBackOnlyWhenEveryLineHasBeenShown() {
		let script = PracticeScript(lines: [
			.init(id: "a", text: "One two.", stage: .sounds, sounds: ["W": 1]),
			.init(id: "b", text: "Three four.", stage: .pairs, sounds: ["TH": 1]),
		])
		var log = PracticeLog(skipped: ["a"])
		var rng = SeededGenerator(state: 1)
		#expect(PracticePicker.pickSet(script: script, log: log, using: &rng).map(\.id) == ["b", "a"])
		log.recordings["b"] = recording("b")
		#expect(PracticePicker.pickSet(script: script, log: log, using: &rng).map(\.id) == ["a"])
		log.recordings["a"] = recording("a")
		#expect(PracticePicker.pickSet(script: script, log: log, using: &rng).isEmpty)
	}

	@Test
	func endlessRunsThroughEveryLineOnce() {
		let script = Self.bundled
		var rng = SeededGenerator(state: 11)
		var picks: [PracticePick] = []
		while let next = PracticePicker.pickNext(script: script, log: PracticeLog(), after: picks, using: &rng) {
			picks.append(next)
		}
		#expect(picks.count == script.lines.count)
		#expect(Set(picks.map(\.id)).count == script.lines.count)
	}

	@Test
	func coverageCountsRecordedLines() {
		let script = PracticeScript(lines: [
			.init(id: "a", text: "x", stage: .sounds, sounds: ["AA": 2, "B": 1], pairs: ["AA-B"]),
			.init(id: "b", text: "y", stage: .detail, sounds: ["K": 1], pairs: ["K-AA"], terms: ["json"]),
		])
		let log = PracticeLog(recordings: ["b": recording("b")])
		let coverage = log.coverage(in: script)
		#expect(coverage.soundsCovered == 1)
		#expect(coverage.terms == ["json"])
		#expect(script.allPairs == ["AA-B", "K-AA"])
	}

	@Test
	func missingAudioIsDroppedButClearedAudioStays() {
		var cleared = recording("b")
		cleared.audioClearedAt = .now
		var log = PracticeLog(recordings: ["a": recording("a"), "b": cleared, "c": recording("c")])
		#expect(log.dropMissingAudio(present: ["c.wav"]) == 1)
		#expect(Set(log.recordings.keys) == ["b", "c"])
	}

	@Test
	func trainedAndUntrained() {
		var trained = recording("a")
		trained.trainedAt = .now
		var gone = recording("b")
		gone.trainedAt = .now
		gone.audioClearedAt = .now
		let log = PracticeLog(recordings: ["a": trained, "b": gone, "c": recording("c")])
		#expect(log.trainedWithAudio.map(\.lineID) == ["a"])
		#expect(log.untrained.map(\.lineID) == ["c"])
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
		log.seen = ["p001", "p003"]
		let decoded = try JSONDecoder().decode(PracticeLog.self, from: JSONEncoder().encode(log))
		#expect(decoded == log)
	}

	@Test
	func readsALogWrittenBeforeSets() throws {
		let json = #"{"recordings":{},"skipped":["p002"]}"#
		let log = try JSONDecoder().decode(PracticeLog.self, from: Data(json.utf8))
		#expect(log.skipped == ["p002"])
		#expect(log.seen.isEmpty)
	}

	@Test
	func theBundledScriptHasSoundDataForEveryLine() {
		let script = Self.bundled
		#expect(script.lines.count > 200)
		#expect(Set(script.lines.map(\.id)).count == script.lines.count)
		#expect(script.lines.allSatisfy { !$0.sounds.isEmpty })
		#expect(Set(script.lines.flatMap(\.sounds.keys)).count == PracticeScript.phonemeCount)
		for stage in PracticeLine.Stage.allCases {
			#expect(script.lines.contains { $0.stage == stage })
		}
	}

	// MARK: - Silence trim

	/// Quiet noise, a key click at 0.1 s, a tone from 1.0 s to 2.0 s, quiet noise to 3.0 s.
	func clip(rate: Double = 16000) -> [Float] {
		var rng = SeededGenerator(state: 5)
		return (0 ..< Int(3 * rate)).map { index in
			let t = Double(index) / rate
			let noise = Float.random(in: -0.0005 ... 0.0005, using: &rng)
			if (0.1 ..< 0.11).contains(t) { return 0.5 }
			if (1.0 ..< 2.0).contains(t) { return Float(0.2 * sin(2 * .pi * 220 * t)) + noise }
			return noise
		}
	}

	@Test
	func trimsSilenceAndTheClickButKeepsAMargin() {
		let range = SilenceTrim.speechRange(samples: clip(), sampleRate: 16000)
		#expect(abs(Double(range.lowerBound) / 16000 - 0.75) < 0.03)
		#expect(abs(Double(range.upperBound) / 16000 - 2.35) < 0.03)
	}

	@Test
	func keepsEverythingWhenNothingStandsOut() {
		#expect(SilenceTrim.speechRange(samples: [Float](repeating: 0, count: 16000), sampleRate: 16000) == 0 ..< 16000)
		#expect(SilenceTrim.speechRange(samples: [0.1, 0.2], sampleRate: 16000) == 0 ..< 2)
	}
}

struct PracticeSpaceKeyTests {
	let t0 = Date(timeIntervalSinceReferenceDate: 0)

	@Test
	func aTapStartsAndTheNextTapStops() {
		var key = PracticeSpaceKey()
		#expect(key.keyDown(isRecording: false, canStart: true, at: t0) == .start)
		#expect(key.keyUp(isRecording: true, at: t0 + 0.2) == .none)
		#expect(key.keyDown(isRecording: true, canStart: true, at: t0 + 5) == .stop)
		#expect(key.keyUp(isRecording: false, at: t0 + 5.1) == .none)
	}

	@Test
	func holdingTwoSecondsOrMoreStopsOnRelease() {
		var key = PracticeSpaceKey()
		#expect(key.keyDown(isRecording: false, canStart: true, at: t0) == .start)
		#expect(key.keyUp(isRecording: true, at: t0 + 2) == .stop)
	}

	@Test
	func aShortHoldStaysRecording() {
		var key = PracticeSpaceKey()
		_ = key.keyDown(isRecording: false, canStart: true, at: t0)
		#expect(key.keyUp(isRecording: true, at: t0 + 1.9) == .none)
		// A later long press that stops doesn't count as a hold of its own.
		#expect(key.keyDown(isRecording: true, canStart: true, at: t0 + 4) == .stop)
		#expect(key.keyUp(isRecording: false, at: t0 + 7) == .none)
	}

	@Test
	func nothingStartsWhileSaving() {
		var key = PracticeSpaceKey()
		#expect(key.keyDown(isRecording: false, canStart: false, at: t0) == .none)
		#expect(key.keyUp(isRecording: false, at: t0 + 3) == .none)
	}
}
