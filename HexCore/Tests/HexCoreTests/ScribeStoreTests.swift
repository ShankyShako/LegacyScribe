import Foundation
import GRDB
@testable import HexCore
import Testing

struct ScribeStoreTests {
	func transcript(_ text: String, secondsAgo: Double, rewritten: Bool = false) -> Transcript {
		Transcript(
			timestamp: Date(timeIntervalSinceReferenceDate: 800_000_000 - secondsAgo + 0.123456),
			text: text,
			audioPath: URL(fileURLWithPath: "/tmp/Recordings/\(text).wav"),
			duration: 2.5,
			sourceAppBundleID: "com.example.chat",
			sourceAppName: "Chat",
			rawText: rewritten ? "um \(text)" : nil,
			rewriteMode: rewritten ? .clean : nil,
			rewrittenBy: rewritten ? "qwen" : nil,
			rewriteFailures: rewritten ? ["primary groq: offline"] : nil,
			latency: rewritten ? DictationLatency(captureMs: 10, transcribeMs: 300, rewriteMs: 500, postProcessMs: 5, pasteMs: 40, audioSeconds: 2.5, engine: "cohere") : nil
		)
	}

	@Test
	func everyFieldRoundTripsNewestFirst() throws {
		let store = try ScribeStore()
		let history = [transcript("newer", secondsAgo: 10, rewritten: true), transcript("older", secondsAgo: 60)]
		try store.sync(history, previous: [])
		#expect(try store.transcripts() == history)
	}

	@Test
	func syncWritesOnlyTheChangesAndDeletesRemovedEntries() throws {
		let store = try ScribeStore()
		let a = transcript("a", secondsAgo: 30), b = transcript("b", secondsAgo: 20)
		try store.sync([b, a], previous: [])

		var edited = a
		edited.audioRemoved = true
		let c = transcript("c", secondsAgo: 5)
		let diff = StoreDiff(old: [b, a], new: [c, edited])
		#expect(diff.upserted.map(\.id) == [c.id, a.id])
		#expect(diff.deleted == [b.id])

		try store.sync([c, edited], previous: [b, a])
		#expect(try store.transcripts() == [c, edited])
	}

	@Test
	func wordTimingsAreReplacedAndGoWithTheirDictation() throws {
		let store = try ScribeStore()
		let a = transcript("a", secondsAgo: 1)
		try store.sync([a], previous: [])
		#expect(try store.words(for: a.id) == nil)

		try store.saveWords([SpokenWord(word: "old", start: 0, end: 1)], for: a.id, source: "test")
		let words = [SpokenWord(word: "hello", start: 0.12, end: 0.48), SpokenWord(word: "there", start: 0.52, end: 0.9)]
		try store.saveWords(words, for: a.id, source: "ctc")
		#expect(try store.words(for: a.id) == words)

		try store.sync([], previous: [a])
		let left = try store.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM words") }
		#expect(left == 0)
	}

	@Test
	func correctionsOutliveTheirDictation() throws {
		let store = try ScribeStore()
		let a = transcript("a", secondsAgo: 1)
		try store.sync([a], previous: [])
		let edit = SentEdit(
			timestamp: Date(timeIntervalSinceReferenceDate: 800_000_000.5), transcriptID: a.id, bundleID: "com.example.chat",
			appName: "Chat", mode: .prompt, recognized: "ship it friday", pasted: "Ship it Friday.", sent: "Ship it Monday."
		)
		try store.syncSentEdits([edit], previous: [])
		try store.sync([], previous: [a])
		#expect(try store.sentEdits() == [edit])
	}

	@Test
	func aDatabaseFromBeforeFailuresGainsTheColumnAndKeepsItsRows() throws {
		let folder = FileManager.default.temporaryDirectory.appending(component: "store-v1-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let path = folder.appending(component: "scribe.sqlite").path

		let old = transcript("before", secondsAgo: 60, rewritten: true)
		do {
			let queue = try DatabaseQueue(path: path)
			try ScribeStore.migrator.migrate(queue, upTo: "v1")
			try queue.write { db in
				try db.execute(
					sql: "INSERT INTO dictations (id, timestamp, text, audioPath, duration) VALUES (?, ?, ?, ?, ?)",
					arguments: [old.id.uuidString, old.timestamp.timeIntervalSinceReferenceDate, old.text, old.audioPath.absoluteString, old.duration]
				)
			}
		}

		let store = try ScribeStore(path: path)
		let migrated = try store.transcripts()
		#expect(migrated.map(\.id) == [old.id])
		#expect(migrated.first?.failure == nil)

		var failed = transcript("", secondsAgo: 5)
		failed.failure = "The model isn't downloaded"
		try store.sync([failed] + migrated, previous: migrated)
		#expect(try store.transcripts().first == failed)
	}

	@Test
	func jsonFilesAreImportedOnceAndKeptAsBackups() throws {
		let folder = FileManager.default.temporaryDirectory.appending(component: "store-import-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }

		let history = TranscriptionHistory(history: [transcript("b", secondsAgo: 1, rewritten: true), transcript("a", secondsAgo: 9)])
		let historyURL = folder.appending(component: "transcription_history.json")
		try JSONEncoder().encode(history).write(to: historyURL)

		let store = try ScribeStore(path: folder.appending(component: "scribe.sqlite").path)
		#expect(try store.importHistoryFile(historyURL) == 2)
		#expect(try store.transcripts() == history.history)
		#expect(!FileManager.default.fileExists(atPath: historyURL.path))
		#expect(FileManager.default.fileExists(atPath: historyURL.path + ".imported"))
		#expect(try store.importHistoryFile(historyURL) == 0)
	}

	@Test
	func anUnreadableFileIsLeftInPlace() throws {
		let folder = FileManager.default.temporaryDirectory.appending(component: "store-bad-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let url = folder.appending(component: "sent_edits.json")
		try Data("{not json".utf8).write(to: url)

		let store = try ScribeStore()
		#expect(throws: (any Error).self) { try store.importSentEditsFile(url) }
		#expect(FileManager.default.fileExists(atPath: url.path))
	}
}
