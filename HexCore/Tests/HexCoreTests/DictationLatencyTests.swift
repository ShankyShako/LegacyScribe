import Foundation
@testable import HexCore
import Testing

struct DictationLatencyTests {
	@Test
	func latencyIsNilUntilEveryStageIsStamped() {
		let keyUp = ContinuousClock.now
		var timeline = DictationTimeline(keyUp: keyUp)
		timeline.captureStopped = keyUp + .milliseconds(10)
		timeline.transcribed = keyUp + .milliseconds(310)
		timeline.postProcessed = keyUp + .milliseconds(330)
		#expect(timeline.latency(audioSeconds: 8, engine: "parakeet") == nil)
	}

	@Test
	func stagesAreMeasuredBetweenConsecutiveStamps() throws {
		let keyUp = ContinuousClock.now
		var timeline = DictationTimeline(keyUp: keyUp)
		timeline.captureStopped = keyUp + .milliseconds(12)
		timeline.transcribed = keyUp + .milliseconds(312)
		timeline.postProcessed = keyUp + .milliseconds(332)
		timeline.pasted = keyUp + .milliseconds(412)

		let latency = try #require(timeline.latency(audioSeconds: 8.12, engine: "parakeet"))
		#expect(latency.captureMs == 12)
		#expect(latency.transcribeMs == 300)
		#expect(latency.postProcessMs == 20)
		#expect(latency.pasteMs == 80)
		#expect(latency.totalMs == 412)
		#expect(latency.summary == "412 ms (capture 12 · STT 300 · save 20 · paste 80) for 8.1 s audio")
	}
}
