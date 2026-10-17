import Foundation

/// A sentence's place in a transcript: the chunk's number, the turn inside the line (0 for an unlabelled
/// line or a gap) and the sentence inside the turn.
public struct NotesTrimPoint: Codable, Equatable, Comparable, Hashable, Sendable {
	public var chunk: Int
	public var turn: Int
	public var sentence: Int

	public init(chunk: Int, turn: Int, sentence: Int) {
		self.chunk = chunk
		self.turn = turn
		self.sentence = sentence
	}

	public static func < (lhs: Self, rhs: Self) -> Bool {
		(lhs.chunk, lhs.turn, lhs.sentence) < (rhs.chunk, rhs.turn, rhs.sentence)
	}
}

/// A left-out stretch: `start` to `end` inclusive. `first` and `last` are the two sentences' texts, so an
/// edited transcript can find the stretch again.
public struct NotesTrim: Codable, Equatable, Sendable {
	public var start: NotesTrimPoint
	public var end: NotesTrimPoint
	public var first: String
	public var last: String

	public init(start: NotesTrimPoint, end: NotesTrimPoint, first: String, last: String) {
		self.start = start
		self.end = end
		self.first = first
		self.last = last
	}

	func contains(_ point: NotesTrimPoint) -> Bool {
		start <= point && point <= end
	}
}

/// One sentence of a transcript, in transcript order.
public struct NotesSentence: Equatable, Sendable {
	public var point: NotesTrimPoint
	public var text: String
	public var speaker: Int?
	public var isGap: Bool
	public var wordCount: Int

	public init(point: NotesTrimPoint, text: String, speaker: Int?, isGap: Bool, wordCount: Int) {
		self.point = point
		self.text = text
		self.speaker = speaker
		self.isGap = isGap
		self.wordCount = wordCount
	}
}

/// A session's `trims.json`: the stretches the user left out of the notes. A separate, reversible layer over
/// the transcript; `transcript.jsonl` is never changed by a trim. `version` counts changes (0 = never
/// trimmed); notes are stale when it differs from the version they were written from.
public struct NotesTrims: Codable, Equatable, Sendable {
	public private(set) var version: Int = 0
	/// Sorted by start, disjoint.
	public private(set) var trims: [NotesTrim] = []

	public init() {}

	// MARK: Sentences

	/// Every sentence of the transcript in order. A gap line is one sentence (the gap marker, 10 words on the
	/// timeline); each turn's sentences come from `NotesSentences.split`; a line without turns is turn 0.
	public static func sentences(of transcript: NotesTranscript) -> [NotesSentence] {
		var result: [NotesSentence] = []
		for line in transcript.lines {
			if line.isGap {
				result.append(NotesSentence(
					point: NotesTrimPoint(chunk: line.chunk, turn: 0, sentence: 0),
					text: NotesTranscript.gapMarker, speaker: nil, isGap: true, wordCount: 10
				))
			} else if let turns = line.turns {
				for (turnIndex, turn) in turns.enumerated() {
					append(NotesSentences.split(turn.text), chunk: line.chunk, turn: turnIndex, speaker: turn.speaker, to: &result)
				}
			} else {
				append(NotesSentences.split(line.text ?? ""), chunk: line.chunk, turn: 0, speaker: nil, to: &result)
			}
		}
		return result
	}

	private static func append(_ texts: [String], chunk: Int, turn: Int, speaker: Int?, to result: inout [NotesSentence]) {
		for (index, text) in texts.enumerated() {
			result.append(NotesSentence(
				point: NotesTrimPoint(chunk: chunk, turn: turn, sentence: index),
				text: text, speaker: speaker, isGap: false, wordCount: NotesTranscript.wordCount(text)
			))
		}
	}

	// MARK: Editing

	/// Leaves out the sentences from `from` to `to` (either order, both inclusive). Merges with every trim it
	/// overlaps or touches. A point that isn't in the transcript changes nothing.
	public mutating func leaveOut(from: NotesTrimPoint, to: NotesTrimPoint, in transcript: NotesTranscript) {
		let sentences = Self.sentences(of: transcript)
		let positions = Dictionary(sentences.enumerated().map { ($1.point, $0) }, uniquingKeysWith: { first, _ in first })
		guard let a = positions[from], let b = positions[to] else { return }
		var low = min(a, b), high = max(a, b)
		var kept: [NotesTrim] = []
		for trim in trims {
			guard let s = positions[trim.start], let e = positions[trim.end] else {
				kept.append(trim)
				continue
			}
			if e + 1 >= low, s - 1 <= high {
				low = min(low, s)
				high = max(high, e)
			} else {
				kept.append(trim)
			}
		}
		kept.append(NotesTrim(start: sentences[low].point, end: sentences[high].point, first: sentences[low].text, last: sentences[high].text))
		trims = kept.sorted { $0.start < $1.start }
		version += 1
	}

	/// Puts the trim at `index` back into the notes.
	public mutating func bringBack(at index: Int) {
		guard trims.indices.contains(index) else { return }
		trims.remove(at: index)
		version += 1
	}

	public func trimIndex(containing point: NotesTrimPoint) -> Int? {
		trims.firstIndex { $0.contains(point) }
	}

	// MARK: Applying

	/// The transcript's lines without the left-out sentences: a turn's text is its kept sentences joined by
	/// one space, a turn or unlabelled line with nothing kept is dropped, and so is a gap inside a trim.
	/// Chunk numbers, `seconds` and `overlapping` stay. Lines no trim touches come back as they were; with no
	/// trims that is `lines`.
	public func applied(to transcript: NotesTranscript) -> [NotesTranscriptLine] {
		guard !trims.isEmpty else { return transcript.lines }
		var result: [NotesTranscriptLine] = []
		for line in transcript.lines {
			if line.isGap {
				if trimIndex(containing: NotesTrimPoint(chunk: line.chunk, turn: 0, sentence: 0)) == nil { result.append(line) }
			} else if let turns = line.turns {
				var keptTurns: [NotesTranscriptTurn] = []
				for (turnIndex, turn) in turns.enumerated() {
					guard let text = keptText(turn.text, chunk: line.chunk, turn: turnIndex) else { continue }
					var copy = turn
					copy.text = text
					keptTurns.append(copy)
				}
				if keptTurns.isEmpty { continue }
				var copy = line
				copy.turns = keptTurns
				copy.text = keptTurns.map(\.text).joined(separator: " ")
				result.append(copy)
			} else {
				guard let text = keptText(line.text ?? "", chunk: line.chunk, turn: 0) else { continue }
				var copy = line
				copy.text = text
				result.append(copy)
			}
		}
		return result
	}

	/// `text` with its left-out sentences removed: itself when none is left out, nil when nothing is kept.
	private func keptText(_ text: String, chunk: Int, turn: Int) -> String? {
		let sentences = NotesSentences.split(text)
		let kept = sentences.enumerated().filter { index, _ in
			trimIndex(containing: NotesTrimPoint(chunk: chunk, turn: turn, sentence: index)) == nil
		}
		if kept.count == sentences.count { return text }
		return kept.isEmpty ? nil : kept.map(\.element).joined(separator: " ")
	}

	// MARK: Re-anchoring

	/// The trims found again in an edited transcript: each trim's first sentence is the first sentence with
	/// that exact text, its last the first one at or after it with that text. A trim that can't be found is
	/// dropped. `version` goes up once if anything changed.
	public func reanchored(to transcript: NotesTranscript) -> NotesTrims {
		let sentences = Self.sentences(of: transcript)
		var found: [NotesTrim] = []
		for trim in trims {
			guard let first = sentences.firstIndex(where: { $0.text == trim.first }),
			      let last = sentences[first...].firstIndex(where: { $0.text == trim.last }) else { continue }
			found.append(NotesTrim(start: sentences[first].point, end: sentences[last].point, first: trim.first, last: trim.last))
		}
		// Duplicate sentence texts can send two trims to the same place: keep the list disjoint.
		var merged: [NotesTrim] = []
		for trim in found.sorted(by: { $0.start < $1.start }) {
			if var previous = merged.last, trim.start <= previous.end {
				if trim.end > previous.end {
					previous.end = trim.end
					previous.last = trim.last
				}
				merged[merged.count - 1] = previous
			} else {
				merged.append(trim)
			}
		}
		var result = self
		if merged != trims {
			result.trims = merged
			result.version += 1
		}
		return result
	}

	/// The first 8 words of the trim's first sentence, "…" appended when cut.
	public static func gist(of trim: NotesTrim, in sentences: [NotesSentence]) -> String {
		let text = sentences.first { $0.point == trim.start }?.text ?? trim.first
		let words = text.split(whereSeparator: \.isWhitespace)
		let head = words.prefix(8).joined(separator: " ")
		return words.count > 8 ? head + "…" : head
	}
}
