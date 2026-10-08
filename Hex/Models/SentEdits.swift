import ComposableArchitecture
import Foundation
import HexCore

extension SharedReaderKey
	where Self == InMemoryKey<PendingSentEdit?>.Default
{
	/// The last paste, waiting for Enter in the field it went into.
	static var pendingSentEdit: Self {
		Self[.inMemory("pendingSentEdit"), default: nil]
	}
}

extension SharedReaderKey
	where Self == FileStorageKey<SentEditLog>.Default
{
	/// Every dictation as it was sent; kept forever, like correction pairs (training data).
	static var sentEdits: Self {
		Self[.fileStorage(.sentEditsURL), default: .init()]
	}
}

extension URL {
	static var sentEditsURL: URL {
		(try? URL.hexApplicationSupport.appending(component: "sent_edits.json"))
			?? URL.documentsDirectory.appending(component: "sent_edits.json")
	}
}
