import Foundation
@testable import HexCore
import Testing

struct SpeakerNamingTests {
	static func person(_ id: String, _ name: String, axis: Int, seconds: Double = 60) -> Voiceprint {
		var voiceprint = Vectors.voiceprint(id: id, isUser: false, embedding: Vectors.axis(axis))
		voiceprint.name = name
		voiceprint.sourceCount = 1
		voiceprint.sourceSeconds = seconds
		return voiceprint
	}

	/// A unit vector at cosine `score` with axis `near`, in the plane of `near` and `other`.
	static func atScore(_ score: Float, near: Int, other: Int) -> [Float] {
		Vectors.mix(score, Vectors.axis(near), (1 - score * score).squareRoot(), Vectors.axis(other))
	}

	@Test
	func namedVoiceprintsSeedTheRegistryAsFixedSpeakers() throws {
		let lee = Self.person("person-lee", "Dr. Lee", axis: 1)
		var registry = SpeakerRegistry(voiceprints: [Vectors.voiceprint(), lee])
		let seeded = try #require(registry.speaker(SpeakerRegistry.rememberedIDBase))
		#expect(seeded.fixed)
		#expect(seeded.name == "Dr. Lee")
		#expect(seeded.voiceprintID == "person-lee")
		#expect(registry.speakerCount == 0)

		// Matched at the voiceprint cutoff, like the user, and the centroid never moves.
		#expect(registry.assign(Self.atScore(0.45, near: 1, other: 7), seconds: 4) == SpeakerRegistry.rememberedIDBase)
		#expect(registry.speaker(SpeakerRegistry.rememberedIDBase)?.embedding == seeded.embedding)
		#expect(registry.label(SpeakerRegistry.rememberedIDBase) == "Dr. Lee")
		// Under the cutoff: a new voice, numbered as if no one were remembered.
		#expect(registry.assign(Self.atScore(0.35, near: 1, other: 8), seconds: 4) == 2)
		#expect(registry.label(2) == "Speaker 2")
		#expect(registry.assign(Vectors.axis(0), seconds: 4) == 1)
		#expect(registry.label(1) == "You")
	}

	@Test
	func aRenameIsStoredInTheRegistryAndUsedByTheLabels() throws {
		let store = VoiceprintStoreTests.temporaryStore()
		defer { try? FileManager.default.removeItem(at: store.directory) }
		let folder = NotesSessionFolder(FileManager.default.temporaryDirectory.appending(component: "notes-\(UUID().uuidString)"))
		try folder.createDirectories()
		defer { try? FileManager.default.removeItem(at: folder.url) }

		var registry = SpeakerRegistry(voiceprints: [Vectors.voiceprint()])
		_ = registry.assign(Vectors.axis(0), seconds: 5)
		_ = registry.assign(Vectors.axis(2), seconds: 340)
		var transcript = NotesTranscript()
		transcript.add(NotesTranscriptLine(chunk: 1, turns: [
			NotesTranscriptTurn(speaker: 2, text: "Posters are A0 portrait."),
			NotesTranscriptTurn(speaker: 1, text: "Can we bring a laptop?"),
		]))

		try SpeakerNaming.apply(name: "  Dr.  Lee ", to: 2, remember: false, registry: &registry, store: store)
		try folder.saveSpeakers(registry)
		let loaded = try #require(folder.loadSpeakers())
		#expect(loaded.label(2) == "Dr. Lee")
		#expect(loaded.speaker(2)?.voiceprintID == nil)
		#expect(store.all().isEmpty)
		// The transcript keeps numbers; labels, Copy and Edit read the name.
		#expect(transcript.lines[0].turns?.map(\.speaker) == [2, 1])
		let text = transcript.paragraphs(labels: loaded.transcriptLabels)
		#expect(text == "Dr. Lee: Posters are A0 portrait.\n\nYou: Can we bring a laptop?")
		#expect(transcript.edited(text, registry: loaded).lines.first?.turns?.first?.speaker == 2)

		// "You" (the voiceprint speaker) can't be renamed; naming someone else "you" makes them the user,
		// shown merged into "You", with no voice saved.
		#expect(throws: SpeakerNamingError.notRenamable) {
			try SpeakerNaming.apply(name: "Me", to: 1, remember: false, registry: &registry, store: store)
		}
		try SpeakerNaming.apply(name: " you ", to: 2, remember: true, registry: &registry, store: store)
		#expect(registry.consolidated().label(2) == "You")
		#expect(registry.consolidated().speakerCount == 1)
		#expect(store.all().isEmpty)
		#expect(SpeakerNaming.cleaned("Dr: Lee\nthe second") == "Dr Lee the second")
	}

	@Test
	func rememberingStoresTheSessionCentroidAndARenameUpdatesIt() throws {
		let store = VoiceprintStoreTests.temporaryStore()
		defer { try? FileManager.default.removeItem(at: store.directory) }
		var registry = SpeakerRegistry(voiceprints: [Vectors.voiceprint()])
		_ = registry.assign(Vectors.axis(2), seconds: 340)

		try SpeakerNaming.apply(name: "Dr. Lee", to: 2, remember: true, registry: &registry, store: store, newID: { "person-a" })
		let saved = try #require(store.load("person-a"))
		#expect(saved.name == "Dr. Lee")
		#expect(!saved.isUser)
		#expect(saved.embedding == Vectors.axis(2))
		#expect(saved.sourceSeconds == 340)
		#expect(registry.speaker(2)?.voiceprintID == "person-a")

		// A later session recognises the voice; renaming it there renames the voiceprint.
		var later = SpeakerRegistry(voiceprints: store.all())
		let id = later.assign(Vectors.axis(2), seconds: 10)
		#expect(later.label(id) == "Dr. Lee")
		try SpeakerNaming.apply(name: "Dr. Priya Lee", to: id, remember: false, registry: &later, store: store)
		#expect(store.load("person-a")?.name == "Dr. Priya Lee")
		#expect(store.all().count == 1)
		#expect(later.label(id) == "Dr. Priya Lee")
	}

	@Test
	func namingSomeoneAlreadyStoredMergesWeightedBySeconds() throws {
		let store = VoiceprintStoreTests.temporaryStore()
		defer { try? FileManager.default.removeItem(at: store.directory) }
		try store.save(Self.person("person-lee", "Dr. Lee", axis: 1, seconds: 300))

		var registry = SpeakerRegistry(voiceprints: [Vectors.voiceprint()])
		_ = registry.assign(Vectors.axis(2), seconds: 100)
		try SpeakerNaming.apply(name: "dr. lee", to: 2, remember: true, registry: &registry, store: store, newID: { "person-new" })

		#expect(store.all().map(\.id) == ["person-lee"])
		let merged = try #require(store.load("person-lee"))
		#expect(merged.name == "dr. lee")
		#expect(merged.sourceSeconds == 400)
		#expect(merged.sourceCount == 2)
		// 3:1 by seconds: (0.75, 0.25) normalized.
		let norm = (Float(0.75 * 0.75 + 0.25 * 0.25)).squareRoot()
		#expect(abs(merged.embedding[1] - 0.75 / norm) < 1e-5)
		#expect(abs(merged.embedding[2] - 0.25 / norm) < 1e-5)
		#expect(abs(Vectors.norm(merged.embedding) - 1) < 1e-5)
		#expect(registry.speaker(2)?.voiceprintID == "person-lee")

		// A recognised person renamed to someone else's name: the two voiceprints become one.
		try store.save(Self.person("person-sam", "Sam", axis: 3, seconds: 0))
		var later = SpeakerRegistry(voiceprints: store.all())
		let sam = later.assign(Vectors.axis(3), seconds: 5)
		try SpeakerNaming.apply(name: "Dr. Lee", to: sam, remember: true, registry: &later, store: store)
		#expect(store.all().map(\.id) == ["person-lee"])
		#expect(later.speaker(sam)?.voiceprintID == "person-lee")
		// Sam had no speech seconds: equal weights.
		#expect(store.load("person-lee")?.sourceSeconds == 400)
	}

	@Test
	func anOldSpeakersFileWithoutNamesStillLoads() throws {
		let folder = NotesSessionFolder(FileManager.default.temporaryDirectory.appending(component: "notes-\(UUID().uuidString)"))
		try folder.createDirectories()
		defer { try? FileManager.default.removeItem(at: folder.url) }
		let zeros = Array(repeating: "0", count: Voiceprint.dimensions - 1).joined(separator: ",")
		// As the first build wrote it: no `name` or `voiceprintID` for other speakers.
		let json = """
		{"speakers":[\
		{"embedding":[1,\(zeros)],"fixed":true,"id":1,"name":"You","seconds":12.5,"turns":3,"voiceprintID":"you"},\
		{"embedding":[0,1,\(zeros.dropFirst(2))],"fixed":false,"id":2,"seconds":40,"turns":5}]}
		"""
		try Data(json.utf8).write(to: folder.speakersURL)
		var registry = try #require(folder.loadSpeakers())
		#expect(registry.label(1) == "You")
		#expect(registry.label(2) == "Speaker 2")
		#expect(registry.speaker(2)?.name == nil)
		#expect(registry.assign(Vectors.axis(9), seconds: 5) == 3)
	}

	@Test
	func aChunkFinishedAfterARenameKeepsTheName() {
		var current = SpeakerRegistry(voiceprints: [Vectors.voiceprint()])
		_ = current.assign(Vectors.axis(2), seconds: 5)
		var chunk = current
		_ = chunk.assign(Vectors.axis(3), seconds: 5)
		current.rename(2, to: "Dr. Lee", voiceprintID: "person-a")
		chunk.adoptNames(from: current)
		#expect(chunk.label(2) == "Dr. Lee")
		#expect(chunk.speaker(2)?.voiceprintID == "person-a")
		#expect(chunk.label(3) == "Speaker 3")
	}
}
