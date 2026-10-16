import Foundation
import GRDB

/// One spoken word and where it sits in the recording, in seconds from the start.
public struct SpokenWord: Codable, Equatable, Sendable {
	public var word: String
	public var start: Double
	public var end: Double

	public init(word: String, start: Double, end: Double) {
		self.word = word
		self.start = start
		self.end = end
	}
}

/// `<data root>/scribe.sqlite`: dictation history, word timings and correction pairs (sent edits), kept
/// forever. Replaced `transcription_history.json` and `sent_edits.json`, which were rewritten whole on every
/// dictation; those files are imported once and kept beside the database as `.imported` backups.
///
/// The app still holds the history as one array (`@Shared`); `sync` writes only the rows that changed.
public final class ScribeStore: Sendable {
	public let writer: any DatabaseWriter

	public init(path: String) throws {
		var configuration = Configuration()
		configuration.label = "ScribeStore"
		writer = try DatabasePool(path: path, configuration: configuration)
		try Self.migrator.migrate(writer)
	}

	/// An empty in-memory store, for tests.
	public init() throws {
		writer = try DatabaseQueue()
		try Self.migrator.migrate(writer)
	}

	static var migrator: DatabaseMigrator {
		var migrator = DatabaseMigrator()
		migrator.registerMigration("v1") { db in
			try db.create(table: "dictations") { t in
				t.primaryKey("id", .text)
				t.column("timestamp", .double).notNull().indexed()
				t.column("text", .text).notNull()
				t.column("rawText", .text)
				t.column("audioPath", .text).notNull()
				t.column("audioRemoved", .boolean).notNull().defaults(to: false)
				t.column("duration", .double).notNull()
				t.column("sourceAppBundleID", .text)
				t.column("sourceAppName", .text)
				t.column("rewriteMode", .text)
				t.column("rewrittenBy", .text)
				t.column("rewriteFailures", .text)
				t.column("latency", .text)
			}
			try db.create(table: "words") { t in
				t.column("dictationID", .text).notNull().references("dictations", onDelete: .cascade)
				t.column("position", .integer).notNull()
				t.column("word", .text).notNull()
				t.column("start", .double).notNull()
				t.column("end", .double).notNull()
				t.column("source", .text).notNull()
				t.primaryKey(["dictationID", "position"])
			}
			// Sent edits: what was pasted and what the user sent. No foreign key, so a pair outlives a
			// history entry the user deletes.
			try db.create(table: "corrections") { t in
				t.primaryKey("id", .text)
				t.column("timestamp", .double).notNull().indexed()
				t.column("dictationID", .text).indexed()
				t.column("bundleID", .text)
				t.column("appName", .text)
				t.column("mode", .text)
				t.column("recognized", .text).notNull()
				t.column("pasted", .text).notNull()
				t.column("sent", .text).notNull()
			}
		}
		// A dictation whose speech-to-text failed: kept with its recording, empty text, and the reason.
		migrator.registerMigration("v2") { db in
			try db.alter(table: "dictations") { t in
				t.add(column: "failure", .text)
			}
		}
		// Speech coach stats per dictation (`CoachClip` as JSON), deleted with the entry. Derived data:
		// "Turn off and delete coach data" empties it and a rerun rebuilds what still has audio.
		migrator.registerMigration("v3") { db in
			try db.create(table: "coach_clips") { t in
				t.primaryKey("dictationID", .text).references("dictations", onDelete: .cascade)
				t.column("analysedAt", .double).notNull()
				t.column("clip", .text).notNull()
			}
		}
		// Filler-free minute results (`CoachMinute` as JSON). Kept with the coach data and deleted with it.
		migrator.registerMigration("v4") { db in
			try db.create(table: "coach_minutes") { t in
				t.primaryKey("id", .text)
				t.column("date", .double).notNull()
				t.column("minute", .text).notNull()
			}
		}
		return migrator
	}

	// MARK: - Dictations

	/// Newest first, as the history list shows them.
	public func transcripts() throws -> [Transcript] {
		try writer.read { db in
			try DictationRow.order(Column("timestamp").desc).fetchAll(db).map(\.transcript)
		}
	}

	/// Writes the difference between two snapshots of the history: changed or new entries are upserted,
	/// missing ones deleted (with their word timings).
	public func sync(_ history: [Transcript], previous: [Transcript]) throws {
		let change = StoreDiff(old: previous, new: history)
		guard !change.isEmpty else { return }
		try writer.write { db in
			for transcript in change.upserted {
				try DictationRow(transcript).upsert(db)
			}
			_ = try DictationRow.deleteAll(db, keys: change.deleted.map(\.uuidString))
		}
	}

	// MARK: - Word timings

	/// Timings stored for a dictation, nil when it hasn't been aligned.
	public func words(for id: UUID) throws -> [SpokenWord]? {
		let rows = try writer.read { db in
			try WordRow.filter(Column("dictationID") == id.uuidString).order(Column("position")).fetchAll(db)
		}
		return rows.isEmpty ? nil : rows.map { SpokenWord(word: $0.word, start: $0.start, end: $0.end) }
	}

	/// Replaces a dictation's timings. `source` names what produced them (an aligner or an engine).
	public func saveWords(_ words: [SpokenWord], for id: UUID, source: String) throws {
		try writer.write { db in
			_ = try WordRow.filter(Column("dictationID") == id.uuidString).deleteAll(db)
			for (position, word) in words.enumerated() {
				try WordRow(dictationID: id.uuidString, position: position, word: word.word, start: word.start, end: word.end, source: source).insert(db)
			}
		}
	}

	// MARK: - Corrections

	/// Oldest first, the order they were captured in.
	public func sentEdits() throws -> [SentEdit] {
		try writer.read { db in
			try CorrectionRow.order(Column("timestamp")).fetchAll(db).map(\.sentEdit)
		}
	}

	public func syncSentEdits(_ edits: [SentEdit], previous: [SentEdit]) throws {
		let change = StoreDiff(old: previous, new: edits)
		guard !change.isEmpty else { return }
		try writer.write { db in
			for edit in change.upserted {
				try CorrectionRow(edit).upsert(db)
			}
			_ = try CorrectionRow.deleteAll(db, keys: change.deleted.map(\.uuidString))
		}
	}

	// MARK: - Speech coach

	public func coachClips() throws -> [CoachClip] {
		try writer.read { db in
			try CoachClipRow.fetchAll(db).compactMap { decodeJSON($0.clip) }
		}
	}

	/// Replaces the stats of each clip's dictation. A clip whose dictation is gone is skipped.
	public func saveCoachClips(_ clips: [CoachClip], analysedAt: Date = Date()) throws {
		try writer.write { db in
			for clip in clips {
				guard try DictationRow.exists(db, key: clip.dictationID.uuidString), let json = encodeJSON(clip) else { continue }
				try CoachClipRow(dictationID: clip.dictationID.uuidString, analysedAt: analysedAt.timeIntervalSinceReferenceDate, clip: json).upsert(db)
			}
		}
	}

	/// Deletes the coach's stats and minute results. History and the voiceprint are separate and stay.
	public func deleteCoachClips() throws {
		_ = try writer.write { db in
			try CoachClipRow.deleteAll(db)
			try CoachMinuteRow.deleteAll(db)
		}
	}

	/// Oldest first.
	public func coachMinutes() throws -> [CoachMinute] {
		try writer.read { db in
			try CoachMinuteRow.order(Column("date")).fetchAll(db).compactMap { decodeJSON($0.minute) }
		}
	}

	public func saveCoachMinute(_ minute: CoachMinute) throws {
		guard let json = encodeJSON(minute) else { return }
		try writer.write { db in
			try CoachMinuteRow(id: minute.id.uuidString, date: minute.date.timeIntervalSinceReferenceDate, minute: json).upsert(db)
		}
	}

	// MARK: - Import

	/// Moves a JSON file the app used before the database into it, once: the file is decoded, its rows
	/// written, and it's renamed to `<name>.imported` only after the write committed. A file that can't be
	/// decoded is left where it is.
	public func importHistoryFile(_ url: URL) throws -> Int {
		try importFile(url) { (history: TranscriptionHistory) in
			try self.sync(history.history, previous: [])
			return history.history.count
		}
	}

	public func importSentEditsFile(_ url: URL) throws -> Int {
		try importFile(url) { (log: SentEditLog) in
			try self.syncSentEdits(log.edits, previous: [])
			return log.edits.count
		}
	}

	private func importFile<Value: Decodable>(_ url: URL, write: (Value) throws -> Int) throws -> Int {
		guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
		let value = try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
		let count = try write(value)
		let backup = url.appendingPathExtension("imported")
		FileManager.default.removeItemIfExists(at: backup)
		try FileManager.default.moveItem(at: url, to: backup)
		return count
	}
}

/// What changed between two snapshots of an identified list.
struct StoreDiff<Element: Identifiable & Equatable> where Element.ID == UUID {
	var upserted: [Element]
	var deleted: [UUID]

	init(old: [Element], new: [Element]) {
		let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
		let after = Set(new.map(\.id))
		upserted = new.filter { before[$0.id] != $0 }
		deleted = old.map(\.id).filter { !after.contains($0) }
	}

	var isEmpty: Bool { upserted.isEmpty && deleted.isEmpty }
}

// MARK: - Rows

private let json: (encoder: JSONEncoder, decoder: JSONDecoder) = {
	let encoder = JSONEncoder()
	encoder.outputFormatting = .sortedKeys
	return (encoder, JSONDecoder())
}()

private func encodeJSON<T: Encodable>(_ value: T?) -> String? {
	value.flatMap { try? json.encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
}

private func decodeJSON<T: Decodable>(_ text: String?) -> T? {
	text.flatMap { try? json.decoder.decode(T.self, from: Data($0.utf8)) }
}

private struct DictationRow: Codable, FetchableRecord, PersistableRecord {
	static let databaseTableName = "dictations"

	var id: String
	// Seconds since the reference date, so a `Date` round-trips exactly.
	var timestamp: Double
	var text: String
	var rawText: String?
	var audioPath: String
	var audioRemoved: Bool
	var duration: Double
	var sourceAppBundleID: String?
	var sourceAppName: String?
	var rewriteMode: String?
	var rewrittenBy: String?
	var rewriteFailures: String?
	var latency: String?
	var failure: String?

	init(_ transcript: Transcript) {
		id = transcript.id.uuidString
		timestamp = transcript.timestamp.timeIntervalSinceReferenceDate
		text = transcript.text
		rawText = transcript.rawText
		audioPath = transcript.audioPath.absoluteString
		audioRemoved = transcript.audioRemoved ?? false
		duration = transcript.duration
		sourceAppBundleID = transcript.sourceAppBundleID
		sourceAppName = transcript.sourceAppName
		rewriteMode = transcript.rewriteMode?.rawValue
		rewrittenBy = transcript.rewrittenBy
		rewriteFailures = encodeJSON(transcript.rewriteFailures)
		latency = encodeJSON(transcript.latency)
		failure = transcript.failure
	}

	var transcript: Transcript {
		Transcript(
			id: UUID(uuidString: id) ?? UUID(),
			timestamp: Date(timeIntervalSinceReferenceDate: timestamp),
			text: text,
			audioPath: URL(string: audioPath) ?? URL(fileURLWithPath: audioPath),
			duration: duration,
			sourceAppBundleID: sourceAppBundleID,
			sourceAppName: sourceAppName,
			rawText: rawText,
			rewriteMode: rewriteMode.flatMap(RewriteMode.init(rawValue:)),
			rewrittenBy: rewrittenBy,
			rewriteFailures: decodeJSON(rewriteFailures),
			latency: decodeJSON(latency),
			audioRemoved: audioRemoved ? true : nil,
			failure: failure
		)
	}
}

private struct WordRow: Codable, FetchableRecord, PersistableRecord {
	static let databaseTableName = "words"

	var dictationID: String
	var position: Int
	var word: String
	var start: Double
	var end: Double
	var source: String
}

private struct CorrectionRow: Codable, FetchableRecord, PersistableRecord {
	static let databaseTableName = "corrections"

	var id: String
	var timestamp: Double
	var dictationID: String?
	var bundleID: String?
	var appName: String?
	var mode: String?
	var recognized: String
	var pasted: String
	var sent: String

	init(_ edit: SentEdit) {
		id = edit.id.uuidString
		timestamp = edit.timestamp.timeIntervalSinceReferenceDate
		dictationID = edit.transcriptID?.uuidString
		bundleID = edit.bundleID
		appName = edit.appName
		mode = edit.mode?.rawValue
		recognized = edit.recognized
		pasted = edit.pasted
		sent = edit.sent
	}

	var sentEdit: SentEdit {
		SentEdit(
			id: UUID(uuidString: id) ?? UUID(),
			timestamp: Date(timeIntervalSinceReferenceDate: timestamp),
			transcriptID: dictationID.flatMap(UUID.init(uuidString:)),
			bundleID: bundleID,
			appName: appName,
			mode: mode.flatMap(RewriteMode.init(rawValue:)),
			recognized: recognized,
			pasted: pasted,
			sent: sent
		)
	}
}

private struct CoachClipRow: Codable, FetchableRecord, PersistableRecord {
	static let databaseTableName = "coach_clips"

	var dictationID: String
	var analysedAt: Double
	var clip: String
}

private struct CoachMinuteRow: Codable, FetchableRecord, PersistableRecord {
	static let databaseTableName = "coach_minutes"

	var id: String
	var date: Double
	var minute: String
}
