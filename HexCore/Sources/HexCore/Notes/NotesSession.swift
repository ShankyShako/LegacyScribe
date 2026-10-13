import Foundation

/// A notes session's `session.json`. The stage says where to pick up after a crash or quit.
public struct NotesSession: Codable, Equatable, Sendable, Identifiable {
	public enum Stage: String, Codable, Sendable {
		/// Capture is running; the transcribe loop drains `pending/` as chunks arrive.
		case recording
		/// Capture stopped; the loop finishes the chunks still pending.
		case transcribing
		/// The local model is writing `notes/part-NN.md`, then `notes.md`.
		case noting
		case done
	}

	/// Also the folder name: `yyyy-MM-dd-HHmmss`, so names sort by start time.
	public var id: String
	public var startedAt: Date
	public var stage: Stage
	/// When capture stopped.
	public var endedAt: Date?
	/// The last notes attempt's error, shown with a Retry button; cleared when notes are written.
	public var notesError: String?
	/// Model that wrote `notes.md`.
	public var notesModel: String?

	public init(id: String, startedAt: Date, stage: Stage = .recording) {
		self.id = id
		self.startedAt = startedAt
		self.stage = stage
	}

	public static func id(for date: Date, timeZone: TimeZone = .current) -> String {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = timeZone
		formatter.dateFormat = "yyyy-MM-dd-HHmmss"
		return formatter.string(from: date)
	}

	/// A session stops at 2 h, which keeps the transcript and the notes pass bounded.
	public static let maxDuration: TimeInterval = 2 * 60 * 60
	/// The indicator warns this long before the cap.
	public static let warningLead: TimeInterval = 5 * 60
}

/// Where a session's files live: `<data root>/Notes/<id>/`.
public struct NotesSessionFolder: Sendable {
	public let url: URL

	public init(_ url: URL) {
		self.url = url
	}

	public var manifestURL: URL { url.appending(component: "session.json") }
	public var pendingURL: URL { url.appending(component: "pending", directoryHint: .isDirectory) }
	public var failedURL: URL { url.appending(component: "failed", directoryHint: .isDirectory) }
	public var partsURL: URL { url.appending(component: "notes", directoryHint: .isDirectory) }
	public var notesURL: URL { url.appending(component: "notes.md") }
	public var transcript: NotesTranscriptFile { NotesTranscriptFile(directory: url) }

	public func pendingChunkURL(_ index: Int) -> URL {
		pendingURL.appending(component: Self.chunkName(index))
	}

	public func failedChunkURL(_ index: Int) -> URL {
		failedURL.appending(component: Self.chunkName(index))
	}

	public func partURL(_ index: Int) -> URL {
		partsURL.appending(component: String(format: "part-%02d.md", index))
	}

	static func chunkName(_ index: Int) -> String {
		String(format: "%05d.wav", index)
	}

	/// Index from a chunk file name (`00042.wav` → 42); nil for anything else, such as a `.partial` file.
	public static func chunkIndex(fromName name: String) -> Int? {
		guard name.hasSuffix(".wav") else { return nil }
		return Int(name.dropLast(4))
	}

	public static func partIndex(fromName name: String) -> Int? {
		guard name.hasPrefix("part-"), name.hasSuffix(".md") else { return nil }
		return Int(name.dropFirst(5).dropLast(3))
	}

	public func createDirectories() throws {
		let fm = FileManager.default
		for directory in [url, pendingURL, failedURL, partsURL] {
			try fm.createDirectory(at: directory, withIntermediateDirectories: true)
		}
	}

	public func loadManifest() -> NotesSession? {
		guard let data = try? Data(contentsOf: manifestURL) else { return nil }
		return try? Self.decoder.decode(NotesSession.self, from: data)
	}

	public func saveManifest(_ session: NotesSession) throws {
		try Self.encoder.encode(session).write(to: manifestURL, options: .atomic)
	}

	/// Chunk indices waiting in `pending/`, oldest first.
	public func pendingChunks() -> [Int] {
		Self.indices(in: pendingURL, parse: Self.chunkIndex(fromName:))
	}

	public func failedChunks() -> [Int] {
		Self.indices(in: failedURL, parse: Self.chunkIndex(fromName:))
	}

	public func savedParts() -> Set<Int> {
		Set(Self.indices(in: partsURL, parse: Self.partIndex(fromName:)))
	}

	static func indices(in directory: URL, parse: (String) -> Int?) -> [Int] {
		let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
		return names.compactMap(parse).sorted()
	}

	static let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		encoder.dateEncodingStrategy = .iso8601
		return encoder
	}()

	static let decoder: JSONDecoder = {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return decoder
	}()
}

/// What to do with an unfinished session found at launch.
public enum NotesRecovery {
	public struct Plan: Equatable, Sendable {
		/// Pending chunks to transcribe, oldest first.
		public var queue: [Int]
		/// Pending chunks already in the transcript: a crash came between the commit and the delete.
		public var alreadyTranscribed: [Int]
		/// The stage to continue in. A session that was recording has lost its capture, so it moves on.
		public var stage: NotesSession.Stage
	}

	public static func plan(stage: NotesSession.Stage, pending: [Int], transcript: NotesTranscript) -> Plan {
		let done = pending.filter { transcript.contains(chunk: $0) }
		let queue = pending.filter { !transcript.contains(chunk: $0) }
		let next: NotesSession.Stage = switch stage {
		case .recording, .transcribing: queue.isEmpty ? .noting : .transcribing
		case .noting, .done: stage
		}
		return Plan(queue: queue, alreadyTranscribed: done, stage: next)
	}
}
