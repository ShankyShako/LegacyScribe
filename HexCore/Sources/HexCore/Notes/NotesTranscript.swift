import Foundation

/// One transcribed chunk of a notes session: `{"chunk": n, "text": "…"}`, or `{"chunk": n, "gap": true}`
/// for a chunk that failed twice (its audio is kept in `failed/`).
public struct NotesTranscriptLine: Codable, Equatable, Sendable {
	public var chunk: Int
	public var text: String?
	public var gap: Bool?

	public init(chunk: Int, text: String) {
		self.chunk = chunk
		self.text = text
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

	public static func text(of lines: [NotesTranscriptLine]) -> String {
		lines
			.map { $0.isGap ? gapMarker : ($0.text ?? "") }
			.filter { !$0.isEmpty }
			.joined(separator: " ")
	}

	/// One paragraph per chunk, as the Transcript tab shows it and the transcript editor edits it.
	public var paragraphs: String {
		lines
			.map { $0.isGap ? Self.gapMarker : ($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
			.joined(separator: "\n\n")
	}

	/// The transcript after `paragraphs` was edited. Paragraphs take the chunk numbers of the shown lines in
	/// order (extra ones are numbered after the last chunk); one left as the gap marker stays a gap. Chunks
	/// that had no text are dropped: the session is finished, so nothing will be added to them.
	public func edited(_ text: String) -> NotesTranscript {
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
		return NotesTranscript(lines: zip(numbers, paragraphs).map { chunk, paragraph in
			paragraph == Self.gapMarker ? .gap(chunk: chunk) : NotesTranscriptLine(chunk: chunk, text: paragraph)
		})
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
