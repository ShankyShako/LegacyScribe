import Foundation

/// A sentence placed on the session's timeline, in seconds from the start.
public struct NotesTimelineSentence: Equatable, Sendable {
	public var point: NotesTrimPoint
	public var speaker: Int?
	public var start: Double
	public var end: Double
	/// The index in `NotesTrims.trims` of the stretch that leaves this sentence out.
	public var trimIndex: Int?

	public init(point: NotesTrimPoint, speaker: Int?, start: Double, end: Double, trimIndex: Int?) {
		self.point = point
		self.speaker = speaker
		self.start = start
		self.end = end
		self.trimIndex = trimIndex
	}
}

/// Estimated positions of a transcript's sentences (DESIGN.md "Notes trimming"). A chunk's length is stored
/// on its line; its sentences share it in proportion to their words. Silence inside a chunk is spread over
/// its words, so a boundary can be off by up to that chunk's silent seconds (usually a few, at most ~20).
public enum NotesTimeline {
	public static let defaultChunkSeconds = 25.0

	/// Chunks without a stored length share what is left of `sessionSeconds` after the known ones, at least
	/// 1 s each; with no `sessionSeconds` they get 25 s each.
	public static func build(_ transcript: NotesTranscript, trims: NotesTrims, sessionSeconds: Double?) -> [NotesTimelineSentence] {
		let lengths = chunkLengths(transcript, sessionSeconds: sessionSeconds)
		let sentences = NotesTrims.sentences(of: transcript)
		var result: [NotesTimelineSentence] = []
		result.reserveCapacity(sentences.count)
		var cursor = 0
		var chunkStart = 0.0
		for (line, length) in zip(transcript.lines, lengths) {
			var end = cursor
			while end < sentences.count, sentences[end].point.chunk == line.chunk { end += 1 }
			let group = sentences[cursor ..< end]
			let words = group.reduce(0) { $0 + $1.wordCount }
			var offset = chunkStart
			for sentence in group {
				let share = words > 0 ? Double(sentence.wordCount) / Double(words) : 1 / Double(group.count)
				let next = offset + length * share
				result.append(NotesTimelineSentence(
					point: sentence.point, speaker: sentence.speaker, start: offset, end: next,
					trimIndex: trims.trimIndex(containing: sentence.point)
				))
				offset = next
			}
			cursor = end
			chunkStart += length
		}
		return result
	}

	static func chunkLengths(_ transcript: NotesTranscript, sessionSeconds: Double?) -> [Double] {
		let known = transcript.lines.compactMap(\.seconds).reduce(0, +)
		let unknown = transcript.lines.filter { $0.seconds == nil }.count
		let share: Double
		if let sessionSeconds, unknown > 0 {
			share = max((sessionSeconds - known) / Double(unknown), 1)
		} else {
			share = defaultChunkSeconds
		}
		return transcript.lines.map { $0.seconds ?? share }
	}

	/// The sentence whose start is nearest `seconds`, for the left handle.
	public static func nearestStart(to seconds: Double, in sentences: [NotesTimelineSentence]) -> NotesTrimPoint? {
		sentences.min { abs($0.start - seconds) < abs($1.start - seconds) }?.point
	}

	/// The sentence whose end is nearest `seconds`, for the right handle.
	public static func nearestEnd(to seconds: Double, in sentences: [NotesTimelineSentence]) -> NotesTrimPoint? {
		sentences.min { abs($0.end - seconds) < abs($1.end - seconds) }?.point
	}

	/// "m:ss", or "h:mm:ss" from an hour.
	public static func clock(_ seconds: Double) -> String {
		let total = max(Int(seconds.rounded()), 0)
		let hours = total / 3600, minutes = total % 3600 / 60, rest = total % 60
		return hours > 0
			? String(format: "%d:%02d:%02d", hours, minutes, rest)
			: String(format: "%d:%02d", minutes, rest)
	}
}
