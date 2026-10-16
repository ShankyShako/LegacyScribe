import Foundation

/// Silent stretches between the first and last word of a recording, found from loudness rather than word
/// timings: Parakeet TDT runs a word's end up to the next word's start, so the gaps between its words
/// don't show where the speaker stopped. A voiced hesitation ("um") isn't silence and isn't a pause here.
/// Loudness alone is trusted: two by-ear checks (2026-10-15) found that vetoing silences with Silero VAD or
/// Parakeet's words dropped mostly real pauses (Silero hears music and the edges of a gap, Parakeet places
/// words in a flat noise floor).
public enum PauseFinder {
	public struct Pause: Equatable, Sendable {
		public var start: Double
		public var seconds: Double
		/// The word before it closes a sentence (. ? !).
		public var endsSentence: Bool
	}

	static let frameSeconds = 0.02
	/// Shorter silences are the gaps of ordinary speech, not pauses.
	public static let minimumPause = 0.3

	/// Silent ranges, in seconds, of at least `minimumPause`.
	public static func silences(in samples: [Float], sampleRate: Double) -> [ClosedRange<Double>] {
		let frameLength = max(1, Int(sampleRate * frameSeconds))
		let frameCount = samples.count / frameLength
		guard frameCount >= 10 else { return [] }
		let levels: [Float] = (0 ..< frameCount).map { frame in
			var sum: Float = 0
			for sample in samples[frame * frameLength ..< (frame + 1) * frameLength] { sum += sample * sample }
			return (sum / Float(frameLength)).squareRoot()
		}
		let sorted = levels.sorted()
		let floor = sorted[sorted.count / 10]
		let loud = sorted[sorted.count * 95 / 100]
		// Like `SilenceTrim`, but against the loud end of speech rather than its single peak, so one
		// pop doesn't raise the bar for the whole recording.
		let threshold = max(floor * 2.5, loud * 0.06, 0.0008)

		var ranges: [ClosedRange<Double>] = []
		var runStart: Int?
		for frame in 0 ... frameCount {
			let quiet = frame < frameCount && levels[frame] < threshold
			if quiet, runStart == nil {
				runStart = frame
			} else if !quiet, let start = runStart {
				let range = Double(start) * frameSeconds ... Double(frame) * frameSeconds
				if range.upperBound - range.lowerBound >= minimumPause { ranges.append(range) }
				runStart = nil
			}
		}
		return ranges
	}

	/// Pauses between the first and last word, each labelled by the word spoken before it.
	public static func pauses(in samples: [Float], sampleRate: Double, words: [SpokenWord]) -> [Pause] {
		guard let first = words.first, let last = words.last else { return [] }
		return silences(in: samples, sampleRate: sampleRate).compactMap { silence in
			// Only silences with speech on both sides; trim to the speaking span.
			let start = max(silence.lowerBound, first.start)
			let end = min(silence.upperBound, last.end)
			guard silence.lowerBound > first.start, silence.upperBound < last.end + 0.2, end - start >= minimumPause else {
				return nil
			}
			// TDT starts a word inside the silence before it, so the word before the pause is the last one
			// that started clearly before the silence did.
			let before = words.last { $0.start < start - 0.02 }
			let endsSentence = before.map { [".", "?", "!"].contains($0.word.last.map(String.init) ?? "") } ?? false
			return Pause(start: start, seconds: end - start, endsSentence: endsSentence)
		}
	}
}
