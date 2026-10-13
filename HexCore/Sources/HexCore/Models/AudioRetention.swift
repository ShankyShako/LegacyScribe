import Foundation

/// Which dictation recordings are due for deletion. Text history is kept forever; only the audio expires.
/// Recordings behind an edited sent text are kept: they are correction pairs, the fine-tuning data.
public enum AudioRetention {
	/// Default for `HexSettings.audioRetentionDays`; 0 keeps audio forever.
	public static let defaultDays = 30

	public static func cutoff(days: Int, now: Date) -> Date? {
		guard days > 0 else { return nil }
		return now.addingTimeInterval(-TimeInterval(days) * 24 * 60 * 60)
	}

	/// History entries the user edited before sending.
	public static func pinned(by edits: [SentEdit]) -> Set<UUID> {
		Set(edits.lazy.filter(\.wasEdited).compactMap(\.transcriptID))
	}

	/// IDs of history entries whose audio should be deleted now.
	public static func expired(
		_ history: [Transcript],
		pinned: Set<UUID>,
		days: Int,
		now: Date
	) -> [UUID] {
		guard let cutoff = cutoff(days: days, now: now) else { return [] }
		return history
			.filter { $0.audioRemoved != true && $0.timestamp < cutoff && !pinned.contains($0.id) }
			.map(\.id)
	}

	/// Recordings on disk that no history entry points at (left behind by a reset or a crash), past the cutoff.
	public static func orphans(
		files: [(url: URL, modified: Date)],
		referenced: Set<String>,
		days: Int,
		now: Date
	) -> [URL] {
		guard let cutoff = cutoff(days: days, now: now) else { return [] }
		return files
			.filter { $0.modified < cutoff && !referenced.contains($0.url.standardizedFileURL.path) }
			.map(\.url)
	}
}
