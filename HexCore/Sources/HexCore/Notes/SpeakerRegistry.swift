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
	/// Speakers shown as someone else (`consolidated()`): a stray to the voice it is nearest, a name used
	/// twice to one of them, "Me" to the user. Never stored: the merges are worked out again on every read, so
	/// renaming a speaker undoes them.
	public private(set) var aliases: [Int: Int] = [:]

	private enum CodingKeys: String, CodingKey {
		case speakers
	}

	/// Speakers seeded from other people's voiceprints are numbered from here, so they never take a
	/// "Speaker N" number: the first unknown voice is still Speaker 2 however many people are remembered.
	public static let rememberedIDBase = 1001

	/// One fixed speaker per voiceprint (pass the user's first): the user's is 1 ("You"), other people's
	/// are numbered from `rememberedIDBase` in the given order and labelled with their names.
	public init(voiceprints: [Voiceprint] = []) {
		var nextUserID = 1
		var nextRememberedID = Self.rememberedIDBase
		speakers = voiceprints.map { voiceprint in
			let id: Int
			if voiceprint.isUser {
				id = nextUserID
				nextUserID += 1
			} else {
				id = nextRememberedID
				nextRememberedID += 1
			}
			return Speaker(
				id: id,
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
		let id = (speakers.map(\.id).filter { $0 < Self.rememberedIDBase }.max() ?? 0) + 1
		speakers.append(Speaker(id: id, name: nil, voiceprintID: nil, fixed: false, embedding: vector, seconds: seconds, turns: 1))
		return id
	}

	/// Names a speaker and links it to a stored voiceprint (nil: none). The user's voiceprint speaker keeps
	/// "You". Returns false for an unknown speaker or the user's.
	@discardableResult
	public mutating func rename(_ id: Int, to name: String?, voiceprintID: String?) -> Bool {
		guard let index = speakers.firstIndex(where: { $0.id == id }),
		      !(speakers[index].fixed && speakers[index].voiceprintID == Voiceprint.userID) else { return false }
		speakers[index].name = name
		speakers[index].voiceprintID = voiceprintID
		return true
	}

	/// Takes names and voiceprint links from `current` for the speakers both know. A chunk's registry is
	/// copied before its turns are transcribed; a speaker named meanwhile must keep the name.
	public mutating func adoptNames(from current: SpeakerRegistry) {
		for index in speakers.indices {
			guard let speaker = current.speaker(speakers[index].id) else { continue }
			speakers[index].name = speaker.name
			speakers[index].voiceprintID = speaker.voiceprintID
		}
	}

	/// The speaker `id` is shown as: itself, or the one it was merged into.
	public func speaker(_ id: Int) -> Speaker? {
		speakers.first { $0.id == resolved(id) }
	}

	public func resolved(_ id: Int) -> Int {
		var id = id
		for _ in 0 ..< speakers.count {
			guard let next = aliases[id] else { break }
			id = next
		}
		return id
	}

	public func label(_ id: Int) -> String {
		speaker(id)?.name ?? "Speaker \(resolved(id))"
	}

	/// Speech by `id` and everyone merged into it.
	public func seconds(of id: Int) -> Double {
		let target = resolved(id)
		return speakers.filter { resolved($0.id) == target }.reduce(0) { $0 + $1.seconds }
	}

	/// Speakers heard in the session (a voiceprint nobody matched doesn't count), merged ones once.
	public var speakerCount: Int {
		Set(speakers.filter { $0.turns > 0 }.map { resolved($0.id) }).count
	}

	// MARK: Merging for display

	/// A speaker with less speech than this (and under `strayMaxShare` of the session's) is a stray: the
	/// diarizer split a moment of someone already heard. On the 42-min two-person conversation of
	/// 2026-10-16 the strays had 8–18 s and the real voices 156 s and more.
	public static let strayMaxSeconds = 30.0
	public static let strayMaxShare = 0.2

	/// What the user typed to say "this speaker is me".
	public static func isSelfName(_ name: String?) -> Bool {
		guard let name = name?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
		return ["me", "you", "myself"].contains(name)
	}

	/// The registry as the transcript shows it:
	/// 1. A speaker named "Me" or "You" is the user: merged into the user's voiceprint speaker if the session
	///    has one, else shown as "You" itself (sessions recorded before the voice was learned).
	/// 2. Speakers given the same name are one person, shown as the one with the most speech.
	/// 3. An unnamed stray goes to the speaker its voice is nearest, if that is within `matchThreshold`;
	///    strays are taken longest first, so a short one can follow a longer one it resembles.
	public func consolidated() -> SpeakerRegistry {
		var result = self
		result.aliases = [:]
		let heard = speakers.filter { $0.turns > 0 }
		let user = speakers.first { $0.voiceprintID == Voiceprint.userID && $0.fixed }

		for speaker in heard where Self.isSelfName(speaker.name) && speaker.voiceprintID != Voiceprint.userID {
			if let user {
				result.aliases[speaker.id] = user.id
			} else if let index = result.speakers.firstIndex(where: { $0.id == speaker.id }) {
				result.speakers[index].name = "You"
				result.speakers[index].voiceprintID = Voiceprint.userID
			}
		}
		// Several "Me"s with no voiceprint speaker: one "You".
		let markedUsers = result.speakers.filter { $0.turns > 0 && $0.voiceprintID == Voiceprint.userID && !$0.fixed && result.aliases[$0.id] == nil }
		if let keep = markedUsers.max(by: { $0.seconds < $1.seconds }) {
			for other in markedUsers where other.id != keep.id { result.aliases[other.id] = keep.id }
		}

		let named = Dictionary(grouping: heard.filter { result.aliases[$0.id] == nil && $0.name != nil && !Self.isSelfName($0.name) }) {
			$0.name!.lowercased()
		}
		for group in named.values where group.count > 1 {
			let keep = group.max { $0.seconds < $1.seconds }!
			for other in group where other.id != keep.id { result.aliases[other.id] = keep.id }
		}

		let total = heard.reduce(0) { $0 + $1.seconds }
		func isStray(_ speaker: Speaker) -> Bool {
			!speaker.fixed && speaker.name == nil && result.aliases[speaker.id] == nil
				&& speaker.seconds < Self.strayMaxSeconds && speaker.seconds < total * Self.strayMaxShare
		}
		let strays = heard.filter(isStray).sorted { $0.seconds > $1.seconds }
		// Merged speakers stay candidates: their own voice is evidence, and `resolved` sends the stray on.
		var settled = heard.filter { !isStray($0) }
		for stray in strays {
			let nearest = settled
				.map { ($0, Voiceprint.cosine(stray.embedding, $0.embedding)) }
				.max { $0.1 < $1.1 }
			if let (target, score) = nearest, score >= Self.matchThreshold {
				result.aliases[stray.id] = result.resolved(target.id)
			}
			settled.append(stray)
		}
		return result
	}

	/// Labels for `NotesTranscript`: only when more than one speaker was heard, so a solo session reads as before.
	public var transcriptLabels: ((Int) -> String?)? {
		guard speakerCount > 1 else { return nil }
		let registry = self
		return { registry.speaker($0) == nil ? nil : registry.label($0) }
	}
}
