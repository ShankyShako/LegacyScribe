import ComposableArchitecture
import Foundation
import HexCore
import XCTest

@testable import Hex

/// The Speech Coach tab (P3.6 D6): analysis only on request, the filler-free minute, and "I stutter".
@MainActor
final class CoachFeatureTests: XCTestCase {
	private func clip(fillers: [String: Int] = ["um": 3], corrections: [String: Int] = ["repeated": 4, "no": 1]) -> CoachClip {
		CoachClip(
			dictationID: UUID(), date: Date(timeIntervalSince1970: 1_791_763_200), engine: "parakeet-tdt-0.6b-v3",
			words: 300, speakingSeconds: 120, fillers: fillers, corrections: corrections
		)
	}

	func testRunAnalysisStreamsProgressThenReloads() async {
		let stored = LockIsolated<[CoachClip]>([])
		let analysed = clip()
		let store = TestStore(initialState: CoachFeature.State()) {
			CoachFeature()
		} withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 1_791_763_200)
			$0.coach.clips = { stored.value }
			$0.coach.minutes = { [] }
			$0.coach.pending = { _ in stored.value.isEmpty ? 2 : 0 }
			$0.coach.analyse = { _, _, _ in
				AsyncThrowingStream { continuation in
					continuation.yield(CoachProgress(done: 0, total: 2, failed: 0))
					continuation.yield(CoachProgress(done: 2, total: 2, failed: 1))
					stored.setValue([analysed])
					continuation.finish()
				}
			}
		}
		store.exhaustivity = .off

		await store.send(.task)
		await store.receive(\.loaded)
		XCTAssertEqual(store.state.pending, 2)
		XCTAssertEqual(store.state.summary.overall.words, 0)

		await store.send(.runAnalysis)
		XCTAssertNotNil(store.state.progress)
		await store.receive(\.progress)
		await store.receive(\.progress)
		await store.receive(\.runFinished)
		XCTAssertNil(store.state.progress)
		XCTAssertEqual(store.state.runNote, "1 of 2 recordings couldn't be analysed.")
		await store.receive(\.loaded)
		XCTAssertEqual(store.state.pending, 0)
		XCTAssertEqual(store.state.summary.overall.fillers, 3)
	}

	func testAnEngineErrorIsShownAndNothingIsStuck() async {
		let store = TestStore(initialState: CoachFeature.State()) {
			CoachFeature()
		} withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 1_791_763_200)
			$0.coach.clips = { [] }
			$0.coach.minutes = { [] }
			$0.coach.pending = { _ in 1 }
			$0.coach.analyse = { _, _, _ in
				AsyncThrowingStream { $0.finish(throwing: NSError(domain: "TranscriptionClient", code: -6, userInfo: [
					NSLocalizedDescriptionKey: "The Speech Coach needs Parakeet or Apple Speech",
				])) }
			}
		}
		store.exhaustivity = .off

		await store.send(.runAnalysis)
		await store.receive(\.runFinished)
		XCTAssertNil(store.state.progress)
		XCTAssertEqual(store.state.runNote, "The Speech Coach needs Parakeet or Apple Speech")
	}

	func testStutterFriendlyStopsCountingRepeats() async {
		var state = CoachFeature.State()
		state.clips = [clip()]
		let store = TestStore(initialState: state) {
			CoachFeature()
		} withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 1_791_763_200)
		}
		store.exhaustivity = .off

		await store.send(.setStutterFriendly(false))
		XCTAssertEqual(store.state.summary.overall.corrections, 5)
		await store.send(.setStutterFriendly(true))
		XCTAssertTrue(store.state.hexSettings.coachStutterFriendly)
		XCTAssertEqual(store.state.summary.overall.corrections, 1)
	}

	func testTheMinuteRecordsScoresAndComparesWithTheBest() async {
		let clock = TestClock()
		let audio = FileManager.default.temporaryDirectory.appendingPathComponent("minute-\(UUID().uuidString).wav")
		let best = CoachMinute(date: Date(timeIntervalSince1970: 0), topic: "old", engine: "p", words: 150, speakingSeconds: 55, fillers: ["um": 2])
		let scored = CoachMinute(date: Date(timeIntervalSince1970: 100), topic: "new", engine: "p", words: 140, speakingSeconds: 55, fillers: ["um": 1])
		var state = CoachFeature.State()
		state.minutes = [best]
		let store = TestStore(initialState: state) {
			CoachFeature()
		} withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.continuousClock = clock
			$0.withRandomNumberGenerator = WithRandomNumberGenerator(LCRNG(seed: 1))
			$0.recording.warmUpRecorder = {}
			$0.recording.startRecording = {}
			$0.recording.stopRecording = { .captured(audio) }
			$0.soundEffects.play = { _ in }
			$0.coach.scoreMinute = { url, topic, _ in
				XCTAssertEqual(url, audio)
				XCTAssertFalse(topic.isEmpty)
				return scored
			}
		}
		store.exhaustivity = .off

		await store.send(.startMinute)
		XCTAssertEqual(store.state.minute?.phase, .ready)
		await store.send(.toggleMinuteRecording)
		XCTAssertEqual(store.state.minute?.phase, .recording(startedAt: Date(timeIntervalSince1970: 100)))
		await store.send(.toggleMinuteRecording)
		await store.receive(\.minuteRecorded)
		XCTAssertEqual(store.state.minute?.audio, audio)
		await store.receive(\.minuteScored)
		XCTAssertEqual(store.state.minute?.phase, .result(scored, previousBest: best))
		XCTAssertEqual(store.state.minutes, [best, scored])
		XCTAssertEqual(store.state.bestMinute, scored)
	}

	func testTheMinuteStopsItselfAfterSixtySeconds() async {
		let clock = TestClock()
		let store = TestStore(initialState: CoachFeature.State()) {
			CoachFeature()
		} withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.continuousClock = clock
			$0.withRandomNumberGenerator = WithRandomNumberGenerator(LCRNG(seed: 1))
			$0.recording.warmUpRecorder = {}
			$0.recording.startRecording = {}
			$0.recording.stopRecording = { .ignored(.noActiveRecording) }
			$0.soundEffects.play = { _ in }
		}
		store.exhaustivity = .off

		await store.send(.startMinute)
		await store.send(.toggleMinuteRecording)
		await clock.advance(by: .seconds(CoachMinute.seconds))
		await store.receive(\.toggleMinuteRecording)
		await store.receive(\.minuteScored)
		XCTAssertEqual(store.state.minute?.phase, .failed("Nothing was recorded. Check the microphone in Settings."))
	}
}


extension CoachFeatureTests {
	/// Found 2026-10-15: "Play it back" left running, then "Try again", and the replay was recorded under the
	/// new take.
	func testTryingAgainStopsThePlayback() async {
		let clock = TestClock()
		let audio = FileManager.default.temporaryDirectory.appendingPathComponent("minute-\(UUID().uuidString).wav")
		let playbackCancelled = LockIsolated(false)
		let minute = CoachMinute(date: Date(timeIntervalSince1970: 100), topic: "t", engine: "p", words: 140, speakingSeconds: 55)
		var state = CoachFeature.State()
		state.minute = CoachFeature.MinuteSession(topic: "t", phase: .result(minute, previousBest: nil), audio: audio)
		let store = TestStore(initialState: state) {
			CoachFeature()
		} withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 200)
			$0.continuousClock = clock
			$0.recording.startRecording = {}
			$0.soundEffects.play = { _ in }
			$0.coach.play = { _, _, _ in
				do {
					try await Task.sleep(for: .seconds(60))
				} catch {
					playbackCancelled.setValue(true)
					throw error
				}
			}
		}
		store.exhaustivity = .off

		await store.send(.playMinute)
		XCTAssertEqual(store.state.playing, "minute")
		await store.send(.toggleMinuteRecording)
		XCTAssertNil(store.state.playing)
		for _ in 0 ..< 100 where !playbackCancelled.value { await Task.yield() }
		XCTAssertTrue(playbackCancelled.value, "the replay is stopped before recording starts")
		XCTAssertEqual(store.state.minute?.phase, .recording(startedAt: Date(timeIntervalSince1970: 200)))

		await store.send(.playMinute)
		XCTAssertNil(store.state.playing, "nothing plays while recording")
		await store.send(.closeMinute)
	}
}

/// A small seeded generator, so topic picks are the same every run.
private struct LCRNG: RandomNumberGenerator {
	var seed: UInt64
	mutating func next() -> UInt64 {
		seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
		return seed
	}
}
