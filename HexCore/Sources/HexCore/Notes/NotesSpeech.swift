import Foundation

/// Keeps silence away from Cohere. Fed a quiet room, it makes up text: a 2026-10-10 session left running
/// produced ~20 minutes of "I'm not sure about the details of the book." and "Thank you.". A voice activity
/// detector picks the speech in each chunk; only that is transcribed, and a chunk with none is skipped.
public enum NotesSpeech {
	/// Less speech than this in a chunk (a cough, a click) counts as none.
	public static let minimumSpeechSeconds = 0.5
	/// Silence put between joined speech stretches, so words from two stretches don't run together.
	public static let joinGapSeconds = 0.2

	/// Dictation audio whose loudest 100 ms stays under this is silence, whatever the VAD says: a near-silent
	/// 11 s recording (loudest −45 dBFS) had 1.1 s Silero called speech, and Cohere wrote "Thank you.". The
	/// quietest real dictation in History ("Yep.") peaks at −27 dBFS. Dictation only: a voice across the
	/// table in a meeting can be much quieter than one at the microphone.
	public static let dictationFloorDecibels: Float = -40

	/// True when no 100 ms of `samples` reaches `dictationFloorDecibels` (RMS, full scale = 1).
	public static func isBelowDictationFloor(_ samples: [Float], sampleRate: Int = NotesChunker.sampleRate) -> Bool {
		let window = max(1, sampleRate / 10)
		let floor = pow(10, dictationFloorDecibels / 20)
		var start = 0
		while start < samples.count {
			let end = min(samples.count, start + window)
			var sum: Float = 0
			for index in start ..< end { sum += samples[index] * samples[index] }
			if (sum / Float(end - start)).squareRoot() >= floor { return false }
			start = end
		}
		return true
	}

	/// The speech stretches of `samples` (sample ranges, any order, may overlap) joined in order with a short
	/// silence between them. Nil when they add up to less than `minimumSpeechSeconds`.
	public static func joined(
		_ samples: [Float],
		ranges: [Range<Int>],
		sampleRate: Int = NotesChunker.sampleRate
	) -> [Float]? {
		let merged = merge(ranges.map { $0.clamped(to: 0 ..< samples.count) }.filter { !$0.isEmpty })
		let speech = merged.reduce(0) { $0 + $1.count }
		guard Double(speech) >= minimumSpeechSeconds * Double(sampleRate) else { return nil }
		let gap = [Float](repeating: 0, count: Int(joinGapSeconds * Double(sampleRate)))
		var out: [Float] = []
		out.reserveCapacity(speech + gap.count * merged.count)
		for (index, range) in merged.enumerated() {
			if index > 0 { out += gap }
			out += samples[range]
		}
		return out
	}

	static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
		var merged: [Range<Int>] = []
		for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
			if let last = merged.last, range.lowerBound <= last.upperBound {
				merged[merged.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
			} else {
				merged.append(range)
			}
		}
		return merged
	}

	/// True when most of the text is the same run of words said over and over, the way Cohere loops on
	/// silence or noise ("I'm going to go to the next slide." three times). Real speech repeats a phrase now
	/// and then, but not across most of a 25-second chunk.
	public static func looksLooped(_ text: String) -> Bool {
		let words = text.lowercased()
			.split { !($0.isLetter || $0.isNumber || $0 == "'") }
			.map(String.init)
		let n = 5
		guard words.count >= 12 else { return false }
		var counts: [ArraySlice<String>: Int] = [:]
		for start in 0 ... words.count - n {
			counts[words[start ..< start + n], default: 0] += 1
		}
		var covered = [Bool](repeating: false, count: words.count)
		for start in 0 ... words.count - n where counts[words[start ..< start + n], default: 0] >= 2 {
			for index in start ..< start + n { covered[index] = true }
		}
		return Double(covered.filter { $0 }.count) / Double(words.count) >= 0.6
	}
}

/// Ends a session nobody is talking in: the session that looped for 20 minutes had been left running.
public struct NotesSilenceWatch: Equatable, Sendable {
	/// Long enough for a pause in a meeting, short enough that a forgotten session stops soon.
	public static let limit: TimeInterval = 10 * 60

	public private(set) var silentSeconds: TimeInterval = 0
	public let limit: TimeInterval

	public init(limit: TimeInterval = Self.limit) {
		self.limit = limit
	}

	/// Adds a chunk; true once the chunks since the last speech reach the limit.
	public mutating func record(seconds: TimeInterval, speech: Bool) -> Bool {
		silentSeconds = speech ? 0 : silentSeconds + seconds
		return silentSeconds >= limit
	}
}
