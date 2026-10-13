import ComposableArchitecture
import Foundation
import HexCore

extension ScribeStore {
	/// `<data root>/scribe.sqlite`, opened on first use. History and sent edits saved as JSON before the
	/// database existed are imported then. Tests get an empty in-memory store.
	static let app: ScribeStore = {
		let logger = HexLog.history
		if isTesting, let store = try? ScribeStore() { return store }
		do {
			let store = try ScribeStore(path: URL.hexApplicationSupport.appending(component: "scribe.sqlite").path)
			do {
				let dictations = try store.importHistoryFile(.transcriptionHistoryURL)
				let edits = try store.importSentEditsFile(.sentEditsURL)
				if dictations + edits > 0 {
					logger.notice("Imported \(dictations) history entries and \(edits) sent edits into scribe.sqlite")
				}
			} catch {
				logger.error("Importing JSON history failed; the files stay where they are: \(error.localizedDescription, privacy: .public)")
			}
			return store
		} catch {
			// Dictation must keep working; history just isn't kept this run.
			logger.fault("scribe.sqlite couldn't be opened, history isn't saved this run: \(error.localizedDescription, privacy: .public)")
			return try! ScribeStore()
		}
	}()
}

/// The last array loaded from or saved to the database, so a save writes only what changed.
private final class Snapshot<Element: Sendable>: @unchecked Sendable {
	private let lock = NSLock()
	private var value: [Element] = []

	func swap(_ new: [Element]) -> [Element] {
		lock.withLock {
			defer { value = new }
			return value
		}
	}
}

/// `@Shared(.transcriptionHistory)` backed by the `dictations` table. The app keeps working with the whole
/// array; each save upserts the entries that changed and deletes the ones that went.
struct TranscriptionHistoryKey: SharedKey {
	private static let snapshot = Snapshot<Transcript>()

	var id: String { "scribe.sqlite/dictations" }

	func load(context _: LoadContext<TranscriptionHistory>, continuation: LoadContinuation<TranscriptionHistory>) {
		do {
			let history = try ScribeStore.app.transcripts()
			_ = Self.snapshot.swap(history)
			continuation.resume(returning: TranscriptionHistory(history: history))
		} catch {
			continuation.resume(throwing: error)
		}
	}

	func subscribe(context _: LoadContext<TranscriptionHistory>, subscriber _: SharedSubscriber<TranscriptionHistory>) -> SharedSubscription {
		SharedSubscription {}
	}

	func save(_ value: TranscriptionHistory, context _: SaveContext, continuation: SaveContinuation) {
		let previous = Self.snapshot.swap(value.history)
		do {
			try ScribeStore.app.sync(value.history, previous: previous)
			continuation.resume()
		} catch {
			// Put the old snapshot back so the next save retries these rows.
			_ = Self.snapshot.swap(previous)
			HexLog.history.error("History not saved: \(error.localizedDescription, privacy: .public)")
			continuation.resume(throwing: error)
		}
	}
}

/// `@Shared(.sentEdits)` backed by the `corrections` table.
struct SentEditsKey: SharedKey {
	private static let snapshot = Snapshot<SentEdit>()

	var id: String { "scribe.sqlite/corrections" }

	func load(context _: LoadContext<SentEditLog>, continuation: LoadContinuation<SentEditLog>) {
		do {
			let edits = try ScribeStore.app.sentEdits()
			_ = Self.snapshot.swap(edits)
			continuation.resume(returning: SentEditLog(edits: edits))
		} catch {
			continuation.resume(throwing: error)
		}
	}

	func subscribe(context _: LoadContext<SentEditLog>, subscriber _: SharedSubscriber<SentEditLog>) -> SharedSubscription {
		SharedSubscription {}
	}

	func save(_ value: SentEditLog, context _: SaveContext, continuation: SaveContinuation) {
		let previous = Self.snapshot.swap(value.edits)
		do {
			try ScribeStore.app.syncSentEdits(value.edits, previous: previous)
			continuation.resume()
		} catch {
			_ = Self.snapshot.swap(previous)
			HexLog.learning.error("Sent edits not saved: \(error.localizedDescription, privacy: .public)")
			continuation.resume(throwing: error)
		}
	}
}

extension SharedReaderKey where Self == TranscriptionHistoryKey.Default {
	static var transcriptionHistory: Self {
		Self[TranscriptionHistoryKey(), default: .init()]
	}
}

extension SharedReaderKey where Self == SentEditsKey.Default {
	/// Every sent edit, kept forever: the learning signal for vocabulary and fine-tuning.
	static var sentEdits: Self {
		Self[SentEditsKey(), default: .init()]
	}
}
