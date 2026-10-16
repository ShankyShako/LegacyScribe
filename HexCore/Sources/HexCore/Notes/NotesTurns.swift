import Foundation

/// A diarizer segment of a notes chunk. `localSpeaker` is the diarizer's own label, only meaningful within
/// the chunk; `range` is in samples; `embedding` is unit length.
public struct SpeakerSegment: Equatable, Sendable {
	public var localSpeaker: String
	public var range: Range<Int>
	public var embedding: [Float]

	public init(localSpeaker: String, range: Range<Int>, embedding: [Float]) {
		self.localSpeaker = localSpeaker
		self.range = range
		self.embedding = embedding
	}
}

/// One speaker's stretch of a chunk, transcribed on its own. `speech` holds the Silero ranges inside it;
/// the audio for Cohere is `NotesSpeech.joined(samples, ranges: turn.speech)`.
public struct NotesTurn: Equatable, Sendable {
	public var localSpeaker: String
	/// Samples. Turns of a chunk don't overlap.
	public var range: Range<Int>
	public var speech: [Range<Int>]
	/// Normalized mean of the speaker's segments in the turn.
	public var embedding: [Float]
	/// The diarizer heard two speakers at once for at least `NotesTurns.overlapSeconds` inside the turn.
	public var overlapping: Bool

	public init(localSpeaker: String, range: Range<Int>, speech: [Range<Int>], embedding: [Float], overlapping: Bool = false) {
		self.localSpeaker = localSpeaker
		self.range = range
		self.speech = speech
		self.embedding = embedding
		self.overlapping = overlapping
	}

	public var speechSamples: Int { speech.reduce(0) { $0 + $1.count } }
}

public enum NotesTurns {
	/// Segments of one speaker closer than this are one turn.
	public static let joinGapSeconds = 1.0
	/// Joining stops at this length (a chunk is at most 30 s anyway).
	public static let maxTurnSeconds = 30.0
	/// A shorter turn is too short to place a voice; it joins its neighbour.
	public static let minTurnSeconds = 1.0
	/// Segments of two speakers overlapping this long inside a turn mark it `overlapping`.
	public static let overlapSeconds = 0.5

	private struct Draft {
		var localSpeaker: String
		var range: Range<Int>
		var embeddings: [[Float]]
	}

	/// The chunk's turns, in order:
	/// - segments are sorted by start; consecutive ones of the same local speaker with gaps under 1 s join,
	///   while the turn stays within 30 s;
	/// - a turn shorter than 1 s joins the turn before it (the next one if it is first) and takes that
	///   turn's speaker; turns of one speaker that meet then are joined as above;
	/// - turns are made disjoint and stretched to meet halfway across the gaps between them, the first from
	///   the first speech and the last to the last, so speech the diarizer left out of every segment still
	///   goes to its nearest turn instead of being lost;
	/// - `speech` is the Silero ranges clipped to the turn; a turn with less than
	///   `NotesSpeech.minimumSpeechSeconds` of it is dropped;
	/// - a turn is `overlapping` when segments of two local speakers overlap by `overlapSeconds` or more
	///   inside its final range.
	public static func turns(
		from segments: [SpeakerSegment],
		speech: [Range<Int>],
		sampleRate: Int = NotesChunker.sampleRate
	) -> [NotesTurn] {
		let joinGap = Int(joinGapSeconds * Double(sampleRate))
		let maxLength = Int(maxTurnSeconds * Double(sampleRate))
		let minLength = Int(minTurnSeconds * Double(sampleRate))

		func joined(_ drafts: [Draft]) -> [Draft] {
			var out: [Draft] = []
			for draft in drafts {
				if var last = out.last, last.localSpeaker == draft.localSpeaker,
				   draft.range.lowerBound - last.range.upperBound < joinGap,
				   max(last.range.upperBound, draft.range.upperBound) - last.range.lowerBound <= maxLength {
					last.range = last.range.lowerBound ..< max(last.range.upperBound, draft.range.upperBound)
					last.embeddings += draft.embeddings
					out[out.count - 1] = last
				} else {
					out.append(draft)
				}
			}
			return out
		}

		var drafts = joined(
			segments
				.filter { !$0.range.isEmpty }
				.sorted { ($0.range.lowerBound, $0.range.upperBound) < ($1.range.lowerBound, $1.range.upperBound) }
				.map { Draft(localSpeaker: $0.localSpeaker, range: $0.range, embeddings: [$0.embedding]) }
		)

		// Short turns join a neighbour, which keeps its speaker and embedding.
		while drafts.count > 1, let index = drafts.firstIndex(where: { $0.range.count < minLength }) {
			let short = drafts.remove(at: index)
			if index > 0 {
				let previous = index - 1
				drafts[previous].range = drafts[previous].range.lowerBound ..< max(drafts[previous].range.upperBound, short.range.upperBound)
			} else {
				drafts[0].range = min(short.range.lowerBound, drafts[0].range.lowerBound) ..< drafts[0].range.upperBound
			}
			drafts = joined(drafts)
		}

		// Disjoint, and meeting halfway across gaps.
		let speechStart = speech.map(\.lowerBound).min()
		let speechEnd = speech.map(\.upperBound).max()
		for index in drafts.indices {
			var lower = drafts[index].range.lowerBound
			var upper = drafts[index].range.upperBound
			if index == 0 {
				lower = min(lower, speechStart ?? lower)
			} else {
				// The previous turn already reaches the middle of the gap, or overlaps this one.
				lower = drafts[index - 1].range.upperBound
			}
			if index == drafts.count - 1 {
				upper = max(upper, speechEnd ?? upper)
			} else {
				let nextStart = drafts[index + 1].range.lowerBound
				if nextStart > upper { upper += (nextStart - upper) / 2 }
			}
			drafts[index].range = lower ..< max(lower, upper)
		}

		let minimumSpeech = Int(NotesSpeech.minimumSpeechSeconds * Double(sampleRate))
		let minimumOverlap = Int(overlapSeconds * Double(sampleRate))
		return drafts.compactMap { draft in
			let clipped = NotesSpeech.merge(speech.map { $0.clamped(to: draft.range) }.filter { !$0.isEmpty })
			let turn = NotesTurn(
				localSpeaker: draft.localSpeaker,
				range: draft.range,
				speech: clipped,
				embedding: Voiceprint.normalizedMean(draft.embeddings),
				overlapping: overlaps(in: draft.range, segments: segments, minimum: minimumOverlap)
			)
			return turn.speechSamples >= minimumSpeech ? turn : nil
		}
	}

	/// Whether two local speakers' segments overlap by at least `minimum` samples within `range`.
	static func overlaps(in range: Range<Int>, segments: [SpeakerSegment], minimum: Int) -> Bool {
		let inside = segments.filter { $0.range.overlaps(range) }
		for (index, a) in inside.enumerated() {
			for b in inside[(index + 1)...] where a.localSpeaker != b.localSpeaker {
				if a.range.clamped(to: b.range).clamped(to: range).count >= minimum { return true }
			}
		}
		return false
	}
}

/// The user talking over someone else's turn, found by the voiceprint where the diarizer gave the stretch
/// to the other speaker (bench-results, "A real meeting, diarized": 2 s windows every 0.5 s over 0.4 ran
/// through both stretches the user spoke over, and gave two lone false hits in 14 min of other voices).
public enum SpeakerOverlap {
	public static let windowSeconds = 2.0
	public static let hopSeconds = 0.5
	/// Windows over `Voiceprint.matchThreshold` needed, so one stray window doesn't count.
	public static let minimumHits = 2

	/// 2 s windows every 0.5 s over `sampleCount` samples of a turn's speech; none under 2 s.
	public static func windows(sampleCount: Int, sampleRate: Int = NotesChunker.sampleRate) -> [Range<Int>] {
		let size = Int(windowSeconds * Double(sampleRate))
		let hop = Int(hopSeconds * Double(sampleRate))
		guard sampleCount >= size, hop > 0 else { return [] }
		return stride(from: 0, through: sampleCount - size, by: hop).map { $0 ..< $0 + size }
	}

	/// The windows' scores against the user's voiceprint say the user is in the turn.
	public static func userHeard(_ scores: [Float]) -> Bool {
		scores.filter { $0 > Voiceprint.matchThreshold }.count >= minimumHits
	}
}
