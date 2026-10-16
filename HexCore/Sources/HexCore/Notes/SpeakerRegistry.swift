import Foundation

/// The speakers of one notes session, kept in `speakers.json` so numbers hold across chunks and restarts.
/// Stored voiceprints are fixed speakers (the user's is 1, "You"); every other voice gets the next number in
/// order of first appearance and a running centroid.
public struct SpeakerRegistry: Codable, Equatable, Sendable {
	public struct Speaker: Codable, Equatable, Sendable {
		public var id: Int
		public var name: String?
		public var voiceprintID: String?
		/// A voiceprint's speaker: its centroid never moves.
		public var fixed: Bool
		/// Unit length.
		public var embedding: [Float]
		/// Speech assigned to the speaker in this session.
		public var seconds: Double
		public var turns: Int

		public init(id: Int, name: String?, voiceprintID: String?, fixed: Bool, embedding: [Float], seconds: Double, turns: Int) {
			self.id = id
			self.name = name
			self.voiceprintID = voiceprintID
			self.fixed = fixed
			self.embedding = embedding
			self.seconds = seconds
			self.turns = turns
		}
	}

	/// A turn this close to a voiceprint is that person (`Voiceprint.matchThreshold`).
	public static let matchThreshold: Float = Voiceprint.matchThreshold
	/// A turn this close to an unnamed speaker's centroid is that speaker. Not measured yet: raise it if a
	/// meeting yields too many speakers, lower it if two voices merge.
	public static let sameSpeakerThreshold: Float = 0.5
	/// A turn with less speech than this can't open a new speaker: its embedding is too unsure (the 18-min
	/// Q&A got five extra speakers of one 1–5 s turn each). It goes to someone already heard instead.
	public static let minNewSpeakerSeconds = 3.0
	/// A short turn scoring at least this against an unnamed speaker goes to the best of them; below it, to
	/// the neighbouring turn's speaker.
	public static let shortTurnFloor: Float = 0.2

	public private(set) var speakers: [Speaker]

	/// One fixed speaker per voiceprint, numbered 1… in the given order (pass the user's first).
	public init(voiceprints: [Voiceprint] = []) {
		speakers = voiceprints.enumerated().map { offset, voiceprint in
			Speaker(
				id: offset + 1,
				name: voiceprint.isUser ? "You" : voiceprint.name,
				voiceprintID: voiceprint.id,
				fixed: true,
				embedding: Voiceprint.normalized(voiceprint.embedding),
				seconds: 0,
				turns: 0
			)
		}
	}

	/// The speaker of a turn with this embedding; adds a speaker when no one is close enough, unless the turn
	/// has under `minNewSpeakerSeconds` of speech. Such a turn goes to the closest unnamed speaker (at least
	/// `shortTurnFloor`), else to `neighbour` (the speaker of the turn before it), without moving anyone's
	/// centroid; only with neither does it open a speaker.
	public mutating func assign(_ embedding: [Float], seconds: Double, neighbour: Int? = nil) -> Int {
		let vector = Voiceprint.normalized(embedding)
		func best(fixed: Bool) -> (index: Int, score: Float)? {
			speakers.indices
				.filter { speakers[$0].fixed == fixed }
				.map { ($0, Voiceprint.cosine(vector, speakers[$0].embedding)) }
				.max { $0.1 < $1.1 }
		}
		if let match = best(fixed: true), match.score >= Self.matchThreshold {
			speakers[match.index].seconds += seconds
			speakers[match.index].turns += 1
			return speakers[match.index].id
		}
		if let match = best(fixed: false), match.score >= Self.sameSpeakerThreshold {
			var speaker = speakers[match.index]
			speaker.embedding = Voiceprint.normalizedMean(
				[speaker.embedding, vector],
				weights: [max(speaker.seconds, 1e-3), max(seconds, 1e-3)]
			)
			speaker.seconds += seconds
			speaker.turns += 1
			speakers[match.index] = speaker
			return speaker.id
		}
		if seconds < Self.minNewSpeakerSeconds {
			let fallback = best(fixed: false).flatMap { $0.score >= Self.shortTurnFloor ? $0.index : nil }
				?? neighbour.flatMap { id in speakers.firstIndex { $0.id == id } }
			if let index = fallback {
				speakers[index].seconds += seconds
				speakers[index].turns += 1
				return speakers[index].id
			}
		}
		let id = (speakers.map(\.id).max() ?? 0) + 1
		speakers.append(Speaker(id: id, name: nil, voiceprintID: nil, fixed: false, embedding: vector, seconds: seconds, turns: 1))
		return id
	}

	public func speaker(_ id: Int) -> Speaker? {
		speakers.first { $0.id == id }
	}

	public func label(_ id: Int) -> String {
		speaker(id)?.name ?? "Speaker \(id)"
	}

	/// Speakers heard in the session (a voiceprint nobody matched doesn't count).
	public var speakerCount: Int {
		speakers.filter { $0.turns > 0 }.count
	}

	/// Labels for `NotesTranscript`: only when more than one speaker was heard, so a solo session reads as before.
	public var transcriptLabels: ((Int) -> String?)? {
		guard speakerCount > 1 else { return nil }
		let registry = self
		return { registry.speaker($0) == nil ? nil : registry.label($0) }
	}
}
