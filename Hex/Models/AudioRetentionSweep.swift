import ComposableArchitecture
import Foundation
import HexCore

/// Deletes dictation recordings older than `audioRetentionDays` and marks their history entries; the text stays.
/// Also converts recordings still kept as WAV to FLAC (`RecordingCompression`), whatever the retention.
/// Runs at launch and every few hours, since the app sits in the menu bar for days.
enum AudioRetentionSweep {
	static let interval: Duration = .seconds(6 * 60 * 60)

	static func run(now: Date = Date()) {
		@Shared(.hexSettings) var hexSettings: HexSettings
		@Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
		@Shared(.sentEdits) var sentEdits: SentEditLog

		compress()
		let days = hexSettings.audioRetentionDays
		guard days > 0 else { return }
		let fm = FileManager.default

		let pinned = AudioRetention.pinned(by: sentEdits.edits)
		let expired = Set(AudioRetention.expired(transcriptionHistory.history, pinned: pinned, days: days, now: now))
		for transcript in transcriptionHistory.history where expired.contains(transcript.id) {
			fm.removeItemIfExists(at: transcript.audioPath)
		}
		if !expired.isEmpty {
			$transcriptionHistory.withLock { history in
				for index in history.history.indices where expired.contains(history.history[index].id) {
					history.history[index].audioRemoved = true
				}
			}
		}

		var orphanCount = 0
		if let folder = try? URL.hexApplicationSupport.appending(component: "Recordings", directoryHint: .isDirectory),
		   let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) {
			let files = urls.compactMap { url -> (url: URL, modified: Date)? in
				guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
				return (url, modified)
			}
			let referenced = Set(transcriptionHistory.history.map(\.audioPath.standardizedFileURL.path))
			let orphans = AudioRetention.orphans(files: files, referenced: referenced, days: days, now: now)
			for url in orphans { fm.removeItemIfExists(at: url) }
			orphanCount = orphans.count
		}

		if !expired.isEmpty || orphanCount > 0 {
			HexLog.history.notice("Audio retention (\(days) days): deleted \(expired.count) recordings, \(orphanCount) orphaned files; kept \(pinned.count) pinned")
		}
	}

	/// Converts the WAV recordings of `ids` (every entry when nil) to FLAC and points their entries at the new
	/// files. The WAV is deleted only after the entry has moved, so a crash leaves a file the entry can reach.
	static func compress(ids: Set<UUID>? = nil) {
		@Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
		let fm = FileManager.default
		let pending = transcriptionHistory.history.filter { transcript in
			transcript.audioRemoved != true && transcript.audioPath.pathExtension.lowercased() == "wav"
				&& (ids?.contains(transcript.id) ?? true) && fm.fileExists(atPath: transcript.audioPath.path)
		}
		var converted = 0, saved: Int64 = 0
		for transcript in pending {
			let wav = transcript.audioPath
			do {
				let wavSize = fileSize(wav)
				let flac = try RecordingCompression.flac(from: wav)
				var moved = false
				$transcriptionHistory.withLock { history in
					guard let index = history.history.firstIndex(where: { $0.id == transcript.id && $0.audioPath == wav }) else { return }
					history.history[index].audioPath = flac
					moved = true
				}
				// The entry was deleted (or changed) meanwhile: the FLAC is the one nothing points at.
				fm.removeItemIfExists(at: moved ? wav : flac)
				if moved {
					converted += 1
					saved += wavSize - fileSize(flac)
				}
			} catch {
				HexLog.history.error("Couldn't convert a recording to FLAC: \(error.localizedDescription, privacy: .public)")
			}
		}
		if converted > 0 {
			let savedText = ByteCountFormatter.string(fromByteCount: saved, countStyle: .file)
			HexLog.history.info("Converted \(converted) recordings to FLAC, saving \(savedText, privacy: .public)")
		}
	}

	/// Bytes used by `Recordings/`, for Settings.
	static func recordingsSize() -> Int64 {
		guard let folder = try? URL.hexApplicationSupport.appending(component: "Recordings", directoryHint: .isDirectory),
		      let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
		else { return 0 }
		return urls.reduce(0) { $0 + fileSize($1) }
	}

	private static func fileSize(_ url: URL) -> Int64 {
		Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
	}
}
