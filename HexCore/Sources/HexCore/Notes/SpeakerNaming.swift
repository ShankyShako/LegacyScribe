import Foundation

public enum SpeakerNamingError: Error, LocalizedError, Equatable {
	case emptyName
	case notRenamable

	public var errorDescription: String? {
		switch self {
		case .emptyName: "Type a name first"
		case .notRenamable: "This speaker can't be renamed"
		}
	}
}

/// Naming a speaker in a notes transcript. The name goes into the session's `SpeakerRegistry` (so the
/// transcript, Edit, Copy and export all use it; the transcript lines keep speaker numbers). With
/// `remember`, the speaker's session centroid is also stored as a named voiceprint that later sessions
/// recognise; a speaker already linked to one renames it. A voiceprint already stored under the same name
/// takes the voice in, averaged by speech seconds, so one person stays one voiceprint.
public enum SpeakerNaming {
	/// `NotesTranscript.edited` reads labels of up to 40 characters.
	public static let maxNameLength = 40
	/// IDs of other people's voiceprints start with this.
	public static let voiceprintIDPrefix = "person-"

	/// The name as stored: trimmed, colons and line breaks turned into spaces (a label ends at its colon),
	/// at most `maxNameLength` characters. Nil when nothing is left.
	public static func cleaned(_ name: String) -> String? {
		let flattened = name
			.replacingOccurrences(of: ":", with: " ")
			.components(separatedBy: .newlines)
			.joined(separator: " ")
			.split(whereSeparator: \.isWhitespace)
			.joined(separator: " ")
		let trimmed = String(flattened.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
		return trimmed.isEmpty ? nil : trimmed
	}

	/// Names `speakerID` in `registry`. Stores or updates a voiceprint when `remember` is set or the speaker
	/// is already linked to a stored one. Voiceprints are written before the caller saves the registry.
	public static func apply(
		name rawName: String,
		to speakerID: Int,
		remember: Bool,
		registry: inout SpeakerRegistry,
		store: VoiceprintStore,
		now: Date = Date(),
		newID: () -> String = { voiceprintIDPrefix + UUID().uuidString.lowercased() }
	) throws {
		guard let name = cleaned(rawName) else { throw SpeakerNamingError.emptyName }
		guard let speaker = registry.speaker(speakerID), !(speaker.fixed && speaker.voiceprintID == Voiceprint.userID) else {
			throw SpeakerNamingError.notRenamable
		}
		// "Me" or "You": the user. Shown as "You" (merged into the user's voiceprint speaker when the session
		// has one, `SpeakerRegistry.consolidated`); no voice is saved, the user's own is learned from dictations.
		if SpeakerRegistry.isSelfName(name) {
			registry.rename(speaker.id, to: "You", voiceprintID: nil)
			return
		}
		let linked = speaker.voiceprintID.flatMap(store.load).flatMap { $0.isUser ? nil : $0 }
		// A remembered voice that was forgotten since: the speaker no longer has a saved voice (a speaker
		// recognised by voice in this session keeps its link, it was recognised).
		var voiceprintID = linked?.id ?? (speaker.fixed ? speaker.voiceprintID : nil)

		if linked != nil || remember {
			let sameName = store.all().first {
				!$0.isUser && $0.id != linked?.id && $0.name?.caseInsensitiveCompare(name) == .orderedSame
			}
			let voice = linked ?? Voiceprint(
				id: newID(),
				name: name,
				isUser: false,
				embedding: Voiceprint.normalized(speaker.embedding),
				enrolledAt: now,
				sourceCount: 1,
				sourceSeconds: speaker.seconds,
				selfScoreMedian: 1
			)
			if var existing = sameName {
				existing = existing.merged(with: voice)
				existing.name = name
				try store.save(existing)
				if let linked { try store.delete(linked.id) }
				voiceprintID = existing.id
			} else {
				var renamed = voice
				renamed.name = name
				try store.save(renamed)
				voiceprintID = renamed.id
			}
		}
		registry.rename(speakerID, to: name, voiceprintID: voiceprintID)
	}
}
