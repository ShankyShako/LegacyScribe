import Foundation
@testable import HexCore
import Testing

/// `SpeakerRegistry.consolidated`: how the transcript merges strays, repeated names and "Me". The numbers
/// mirror the 42-min two-person conversation of 2026-10-16 (six speakers heard).
struct SpeakerConsolidationTests {
	private static func unit(_ parts: [Int: Float]) -> [Float] {
		var vector = [Float](repeating: 0, count: 8)
		for (index, value) in parts { vector[index] = value }
		return Voiceprint.normalized(vector)
	}

	private static func registry(_ speakers: [SpeakerRegistry.Speaker]) throws -> SpeakerRegistry {
		let data = try JSONEncoder().encode(["speakers": speakers])
		return try JSONDecoder().decode(SpeakerRegistry.self, from: data)
	}

	private static func speaker(
		_ id: Int, _ seconds: Double, _ embedding: [Float], name: String? = nil, voiceprintID: String? = nil, fixed: Bool = false
	) -> SpeakerRegistry.Speaker {
		.init(id: id, name: name, voiceprintID: voiceprintID, fixed: fixed, embedding: embedding, seconds: seconds, turns: 3)
	}

	/// 1 is the user (named "Me" before the voice was learned), 2 and 3 the other person (named alike),
	/// 4–6 strays: 4 near 2 (0.45), 5 near 3 (0.57), 6 nearest 4 (0.44, 0.33 to 2).
	private static func conversation() throws -> SpeakerRegistry {
		try registry([
			Self.speaker(1, 782, Self.unit([0: 1]), name: "Me", voiceprintID: "person-me"),
			Self.speaker(2, 156, Self.unit([1: 1]), name: "Vendor"),
			Self.speaker(3, 1035, Self.unit([2: 1]), name: "vendor"),
			Self.speaker(4, 18, Self.unit([1: 0.45, 3: 0.893])),
			Self.speaker(5, 13, Self.unit([2: 0.57, 4: 0.822])),
			Self.speaker(6, 8, Self.unit([1: 0.33, 3: 0.3264, 5: 0.8856])),
		])
	}

	@Test
	func aTwoPersonConversationShowsTwoSpeakers() throws {
		let raw = try Self.conversation()
		#expect(raw.speakerCount == 6)
		let shown = raw.consolidated()
		#expect(shown.speakerCount == 2)
		#expect(shown.label(1) == "You")
		#expect(shown.speaker(1)?.voiceprintID == Voiceprint.userID)
		// The name used twice goes to the speaker with more speech; strays follow, 6 through 4.
		for id in [2, 4, 5, 6] { #expect(shown.resolved(id) == 3) }
		#expect(shown.label(4) == "vendor")
		#expect(shown.seconds(of: 2) == 156 + 1035 + 18 + 13 + 8)
	}

	@Test
	func mergesAreNotStored() throws {
		let shown = try Self.conversation().consolidated()
		let reloaded = try JSONDecoder().decode(SpeakerRegistry.self, from: JSONEncoder().encode(shown))
		#expect(reloaded.aliases.isEmpty)
	}

	@Test
	func meJoinsTheUsersVoiceprintSpeaker() throws {
		let shown = try Self.registry([
			Self.speaker(1, 300, Self.unit([0: 1]), name: "You", voiceprintID: Voiceprint.userID, fixed: true),
			Self.speaker(2, 200, Self.unit([1: 1])),
			Self.speaker(3, 60, Self.unit([2: 1]), name: "me"),
		]).consolidated()
		#expect(shown.resolved(3) == 1)
		#expect(shown.label(3) == "You")
		#expect(shown.speakerCount == 2)
	}

	@Test
	func aStrayUnlikeEveryoneStays() throws {
		let shown = try Self.registry([
			Self.speaker(1, 300, Self.unit([0: 1])),
			Self.speaker(2, 200, Self.unit([1: 1])),
			Self.speaker(3, 20, Self.unit([0: 0.35, 2: 0.937])),
		]).consolidated()
		#expect(shown.resolved(3) == 3)
		#expect(shown.speakerCount == 3)
	}

	@Test
	func aShortSessionKeepsItsSpeakers() throws {
		// Everyone is under 30 s, and 20 s is a third of the speech: not a stray.
		let shown = try Self.registry([
			Self.speaker(1, 25, Self.unit([0: 1])),
			Self.speaker(2, 20, Self.unit([0: 0.6, 1: 0.8])),
		]).consolidated()
		#expect(shown.speakerCount == 2)
	}

	@Test
	func aNamedSpeakerIsNeverAStray() throws {
		let shown = try Self.registry([
			Self.speaker(1, 300, Self.unit([0: 1])),
			Self.speaker(2, 10, Self.unit([0: 0.9, 1: 0.436]), name: "Sam"),
		]).consolidated()
		#expect(shown.resolved(2) == 2)
	}
}
