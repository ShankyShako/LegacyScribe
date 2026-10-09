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

extension SharedReaderKey
	where Self == FileStorageKey<PracticeLog>.Default
{
	/// Which practice lines are recorded or skipped; the audio sits next to it.
	static var practiceLog: Self {
		Self[.fileStorage(.practiceFolderURL.appending(component: "practice_log.json")), default: .init()]
	}
}

extension URL {
	/// `<data root>/calibration/`: practice recordings as `<line id>.wav` + `.txt`, an `lsbench` fixture folder.
	static var practiceFolderURL: URL {
		(try? URL.hexApplicationSupport.appending(component: "calibration", directoryHint: .isDirectory))
			?? URL.documentsDirectory.appending(component: "calibration", directoryHint: .isDirectory)
	}
}

extension PracticeScript {
	/// The bundled script, `Resources/Data/practice_lines.json` (built by `tools/practice/order_lines.py`).
	static let bundled: PracticeScript = {
		guard let url = Bundle.main.url(forResource: "practice_lines", withExtension: "json")
			?? Bundle.main.url(forResource: "practice_lines", withExtension: "json", subdirectory: "Data"),
			let data = try? Data(contentsOf: url),
			let script = try? JSONDecoder().decode(PracticeScript.self, from: data)
		else {
			HexLog.learning.error("practice_lines.json missing from the app bundle")
			return PracticeScript(lines: [])
		}
		return script
	}()
}

extension PracticeScript {
	/// Sound pairs in the bundled script, for "% of sound combinations".
	static let bundledPairCount = bundled.allPairs.count
}
