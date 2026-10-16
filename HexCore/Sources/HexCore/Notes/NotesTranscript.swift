import Foundation

/// One speaker's words in a chunk; `speaker` is an ID in the session's `SpeakerRegistry` (`speakers.json`).
/// `overlapping` is stored only when true (`{"overlapping": true}`): another voice was heard at the same time.
public struct NotesTranscriptTurn: Codable, Equatable, Sendable {
	public var speaker: Int
	public var text: String
	public var overlapping: Bool?

	public init(speaker: Int, text: String, overlapping: Bool = false) {
		self.speaker = speaker
		self.text = text
		self.overlapping = overlapping ? true : nil
	}

	public var isOverlapping: Bool { overlapping == true }
}

/// A paragraph of the transcript as the Transcript tab shows it: one per speaker turn, or one per unlabelled
/// chunk or gap (`speaker` nil).
public struct NotesTranscriptParagraph: Equatable, Sendable {
	public var speaker: Int?
	public var text: String
	public var overlapping: Bool

	public init(speaker: Int?, text: String, overlapping: Bool = false) {
		self.speaker = speaker
		self.text = text
		self.overlapping = overlapping
	}
}

/// One transcribed chunk of a notes session: `{"chunk": n, "text": "…"}`, or `{"chunk": n, "gap": true}`
/// for a chunk that failed twice (its audio is kept in `failed/`). A chunk split by speaker also has
/// `"turns": [{"speaker": 1, "text": "…"}, …]`; its `text` is still the plain chunk text (the turns joined),
/// so everything that reads `text`, and an older app, works unchanged. A line without `turns` is one
/// unlabelled chunk.
public struct NotesTranscriptLine: Codable, Equatable, Sendable {
	public var chunk: Int
	public var text: String?
	public var gap: Bool?
	public var turns: [NotesTranscriptTurn]?

	public init(chunk: Int, text: String) {
		self.chunk = chunk
		self.text = text
	}

	/// `text` is the turns' texts joined by a space; no turns is an empty line.
	public init(chunk: Int, turns: [NotesTranscriptTurn]) {
		self.chunk = chunk
		self.text = turns.map(\.text).joined(separator: " ")
		self.turns = turns.isEmpty ? nil : turns
	}

	/// The line as shown with speaker labels: one entry per turn, `"<label>: <text>"` where `labels` names
	/// the speaker; the plain text for an unlabelled line or a speaker without a label.
	func labelled(_ labels: (Int) -> String?) -> [String] {
		if isGap { return [NotesTranscript.gapMarker] }
		guard let turns else { return [(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)] }
		return turns.map { turn in
			let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !text.isEmpty, let label = labels(turn.speaker) else { return text }
			return "\(label): \(text)"
		}
	}

	public static func gap(chunk: Int) -> Self {
		var line = Self(chunk: chunk, text: "")
		line.text = nil
		line.gap = true
		return line
	}

	public var isGap: Bool { gap == true }
}

/// A notes session's transcript, stored as JSONL with one line per chunk. The chunk index makes adding
/// idempotent: a chunk already in the transcript is never added twice, so recovery can replay safely.
public struct NotesTranscript: Equatable, Sendable {
	/// Sorted by chunk index, one line per chunk.
	public private(set) var lines: [NotesTranscriptLine] = []

	public init(lines: [NotesTranscriptLine] = []) {
		for line in lines { add(line) }
	}

	public var lastChunk: Int? { lines.last?.chunk }

	public func contains(chunk: Int) -> Bool {
		lines.contains { $0.chunk == chunk }
	}

	/// False when the chunk is already there (the line is ignored).
	@discardableResult
	public mutating func add(_ line: NotesTranscriptLine) -> Bool {
		guard !contains(chunk: line.chunk) else { return false }
		let index = lines.firstIndex { $0.chunk > line.chunk } ?? lines.endIndex
		lines.insert(line, at: index)
		return true
	}

	public var gapCount: Int { lines.filter(\.isGap).count }

	/// No chunk has words and none failed: nothing was said (or only silence and loops were heard).
	public var heardNothing: Bool {
		!lines.contains { $0.isGap || !($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
	}

	/// The whole transcript as prose; a gap is marked so the notes can say something is missing.
	public var text: String {
		Self.text(of: lines)
	}

	public static let gapMarker = "[gap: this stretch of audio could not be transcribed]"

	/// Prose for the notes writer. With `labels` (`SpeakerRegistry.transcriptLabels`, given only when the
	/// session heard more than one speaker), each turn is its own line, `"<label>: <text>"`.
	public static func text(of lines: [NotesTranscriptLine], labels: ((Int) -> String?)? = nil) -> String {
		guard let labels else {
			return lines
				.map { $0.isGap ? gapMarker : ($0.text ?? "") }
				.filter { !$0.isEmpty }
				.joined(separator: " ")
		}
		return lines
			.flatMap { $0.labelled(labels) }
			.filter { !$0.isEmpty }
			.joined(separator: "\n")
	}

	/// One paragraph per chunk, as the Transcript tab shows it and the transcript editor edits it.
	public var paragraphs: String {
		paragraphs()
	}

	/// Without `labels`, one paragraph per chunk; with them, one per turn, `"<label>: <text>"`, which `edited`
	/// reads back.
	public func paragraphs(labels: ((Int) -> String?)? = nil) -> String {
		lines
			.flatMap { line -> [String] in
				guard let labels else {
					return [line.isGap ? Self.gapMarker : (line.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)]
				}
				return line.labelled(labels)
			}
			.filter { !$0.isEmpty }
			.joined(separator: "\n\n")
	}

	/// One entry per speaker turn (unlabelled chunks and gaps have no speaker), in the order of `paragraphs(labels:)`.
	public var speakerParagraphs: [NotesTranscriptParagraph] {
		lines.flatMap { line -> [NotesTranscriptParagraph] in
			if line.isGap { return [NotesTranscriptParagraph(speaker: nil, text: Self.gapMarker)] }
			guard let turns = line.turns else {
				return [NotesTranscriptParagraph(speaker: nil, text: (line.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))]
			}
			return turns.map {
				NotesTranscriptParagraph(
					speaker: $0.speaker, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), overlapping: $0.isOverlapping
				)
			}
		}
		.filter { !$0.text.isEmpty }
	}

	/// The transcript after `paragraphs` was edited. Paragraphs take the chunk numbers of the shown lines in
	/// order (extra ones are numbered after the last chunk); one left as the gap marker stays a gap. Chunks
	/// that had no text are dropped: the session is finished, so nothing will be added to them. A paragraph
	/// that starts with a label of a speaker in `registry` (`"You: "`, `"Speaker 2: "`) becomes a line with
	/// one turn of that speaker; any other paragraph is an unlabelled line.
	public func edited(_ text: String, registry: SpeakerRegistry? = nil) -> NotesTranscript {
		let paragraphs = text
			.replacingOccurrences(of: "\r\n", with: "\n")
			.components(separatedBy: "\n\n")
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		var numbers = lines.filter { $0.isGap || !($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.chunk)
		var next = (lastChunk ?? -1) + 1
		while numbers.count < paragraphs.count {
			numbers.append(next)
			next += 1
		}
		var speakers: [String: Int] = [:]
		for speaker in registry?.speakers ?? [] where speakers[registry!.label(speaker.id)] == nil {
			speakers[registry!.label(speaker.id)] = speaker.id
		}
		return NotesTranscript(lines: zip(numbers, paragraphs).map { chunk, paragraph in
			if paragraph == Self.gapMarker { return .gap(chunk: chunk) }
			if let (speaker, rest) = Self.speakerAndText(paragraph, speakers: speakers) {
				return NotesTranscriptLine(chunk: chunk, turns: [NotesTranscriptTurn(speaker: speaker, text: rest)])
			}
			return NotesTranscriptLine(chunk: chunk, text: paragraph)
		})
	}

	/// The speaker and text of `"<label>: <text>"`, for a label of up to 40 characters (no colon or line
	/// break) that names one of `speakers`.
	static func speakerAndText(_ paragraph: String, speakers: [String: Int]) -> (Int, String)? {
		guard !speakers.isEmpty, let colon = paragraph.range(of: ": ") else { return nil }
		let label = paragraph[..<colon.lowerBound]
		guard (1 ... 40).contains(label.count), !label.contains(":"), !label.contains("\n"),
		      let speaker = speakers[String(label)] else { return nil }
		let rest = paragraph[colon.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
		return rest.isEmpty ? nil : (speaker, rest)
	}

	public static func wordCount(_ text: String) -> Int {
		text.split(whereSeparator: \.isWhitespace).count
	}

	public func encoded() throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		var data = Data()
		for line in lines {
			data.append(try encoder.encode(line))
			data.append(0x0A)
		}
		return data
	}

	/// Nil unless every line parses and the file ends with a newline, so a torn write never counts.
	public static func parse(_ data: Data) -> NotesTranscript? {
		guard !data.isEmpty else { return NotesTranscript() }
		guard data.last == 0x0A else { return nil }
		let decoder = JSONDecoder()
		var transcript = NotesTranscript()
		for row in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
			guard let line = try? decoder.decode(NotesTranscriptLine.self, from: Data(row)) else { return nil }
			transcript.add(line)
		}
		return transcript
	}
}

/// The transcript's three files in a session folder. `commit` writes `transcript.new` and fsyncs it, renames
/// `transcript.jsonl` to `transcript.bak`, then `transcript.new` to `transcript.jsonl`; a crash at any step
/// leaves at least one complete file, and `load` picks the newest complete one.
public struct NotesTranscriptFile: Sendable {
	public let directory: URL

	public init(directory: URL) {
		self.directory = directory
	}

	public var currentURL: URL { directory.appending(component: "transcript.jsonl") }
	var newURL: URL { directory.appending(component: "transcript.new") }
	var backupURL: URL { directory.appending(component: "transcript.bak") }

	/// The complete file with the highest chunk index (the current file wins a tie); empty if there is none.
	public func load() -> NotesTranscript {
		let candidates = [currentURL, newURL, backupURL].compactMap { url -> NotesTranscript? in
			guard let data = try? Data(contentsOf: url) else { return nil }
			return NotesTranscript.parse(data)
		}
		var best = NotesTranscript()
		for candidate in candidates where (candidate.lastChunk ?? -1) > (best.lastChunk ?? -1) {
			best = candidate
		}
		return best
	}

	public func commit(_ transcript: NotesTranscript) throws {
		let fm = FileManager.default
		let data = try transcript.encoded()
		fm.removeItemIfExists(at: newURL)
		guard fm.createFile(atPath: newURL.path, contents: nil) else {
			throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: newURL.path])
		}
		let handle = try FileHandle(forWritingTo: newURL)
		do {
			try handle.write(contentsOf: data)
			try handle.synchronize()
			try handle.close()
		} catch {
			try? handle.close()
			throw error
		}
		if fm.fileExists(atPath: currentURL.path) {
			try Self.move(currentURL, to: backupURL)
		}
		try Self.move(newURL, to: currentURL)
		Self.syncDirectory(directory)
	}

	/// Commits a transcript the user edited. `load` prefers the file with the highest chunk, so an edit that
	/// removed the last chunks would lose to the backup; committing twice makes the backup the edit as well.
	/// The transcript as first recorded is kept once as `transcript.original.jsonl`.
	public func commitEdit(_ transcript: NotesTranscript) throws {
		let fm = FileManager.default
		if !fm.fileExists(atPath: originalURL.path), fm.fileExists(atPath: currentURL.path) {
			try fm.copyItem(at: currentURL, to: originalURL)
		}
		try commit(transcript)
		try commit(transcript)
	}

	public var originalURL: URL { directory.appending(component: "transcript.original.jsonl") }

	/// POSIX rename: atomic, and replaces the destination.
	static func move(_ source: URL, to destination: URL) throws {
		guard rename(source.path, destination.path) == 0 else {
			throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
		}
	}

	/// Makes the renames themselves durable.
	static func syncDirectory(_ url: URL) {
		let fd = open(url.path, O_RDONLY)
		guard fd >= 0 else { return }
		_ = fsync(fd)
		_ = close(fd)
	}
}
