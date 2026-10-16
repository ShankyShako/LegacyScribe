import Foundation
@testable import HexCore
import Testing

struct CohereChunksTests {
	let rate = 16_000

	/// A 150 Hz tone with silences of `gap` seconds at the given seconds.
	func speech(seconds: Double, gaps: [Double] = [], gap: Double = 0.4) -> [Float] {
		(0 ..< Int(seconds * Double(rate))).map { index in
			let time = Double(index) / Double(rate)
			if gaps.contains(where: { time >= $0 && time < $0 + gap }) { return 0 }
			return Float(sin(time * 2 * .pi * 150)) * 0.3
		}
	}

	@Test
	func upToThirtySecondsIsOnePass() {
		// 25.2 s of speech used to leave a 0.2 s sliver after the 25 s cut, transcribed as "Thank you."
		for seconds in [0.5, 25.2, 29.9] {
			let samples = speech(seconds: seconds, gaps: [seconds - 0.3])
			#expect(CohereChunks.ranges(samples, sampleRate: rate) == [0 ..< samples.count])
		}
	}

	@Test
	func longerAudioIsCutEvenlyAtAQuietPoint() {
		// 40 s: two pieces, cut in the silence nearest the 20 s mark rather than at 25 s.
		let samples = speech(seconds: 40, gaps: [18.5, 26])
		let ranges = CohereChunks.ranges(samples, sampleRate: rate)
		#expect(ranges.count == 2)
		let cut = Double(ranges[0].upperBound) / Double(rate)
		#expect(cut > 18.5 && cut < 18.9)
		#expect(ranges[0].lowerBound == 0 && ranges[1].upperBound == samples.count && ranges[0].upperBound == ranges[1].lowerBound)
	}

	@Test
	func piecesStayBetweenNineAndThirtySeconds() {
		for seconds in [30.5, 49, 73.1, 121] {
			let ranges = CohereChunks.ranges(speech(seconds: seconds), sampleRate: rate)
			#expect(ranges.count == Int((seconds / 24).rounded(.up)))
			for range in ranges {
				let length = Double(range.count) / Double(rate)
				#expect(length >= 9 && length <= 30)
			}
		}
	}
}
