import Foundation
@testable import HexCore
import Testing

/// Unit vectors in 256 dimensions for the speaker tests.
enum Vectors {
	static func axis(_ index: Int) -> [Float] {
		var vector = [Float](repeating: 0, count: Voiceprint.dimensions)
		vector[index] = 1
		return vector
	}

	/// `a * x + b * y`.
	static func mix(_ a: Float, _ x: [Float], _ b: Float, _ y: [Float]) -> [Float] {
		zip(x, y).map { a * $0 + b * $1 }
	}

	static func norm(_ vector: [Float]) -> Float {
		vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
	}

	static func voiceprint(id: String = Voiceprint.userID, isUser: Bool = true, embedding: [Float] = axis(0)) -> Voiceprint {
		Voiceprint(
			id: id, isUser: isUser, embedding: embedding, enrolledAt: Date(timeIntervalSince1970: 1_800_000_000),
			sourceCount: 40, sourceSeconds: 300, selfScoreMedian: 0.75
		)
	}
}

struct VoiceprintStoreTests {
	static func temporaryStore() -> VoiceprintStore {
		VoiceprintStore(directory: FileManager.default.temporaryDirectory.appending(component: "voiceprints-\(UUID().uuidString)"))
	}

	@Test
	func savesLoadsListsAndDeletes() throws {
		let store = Self.temporaryStore()
		defer { try? FileManager.default.removeItem(at: store.directory) }
		#expect(store.load(Voiceprint.userID) == nil)
		#expect(store.all().isEmpty)

		let user = Vectors.voiceprint()
		var priya = Vectors.voiceprint(id: "priya", isUser: false, embedding: Vectors.axis(1))
		priya.name = "Priya"
		try store.save(priya)
		try store.save(user)
		#expect(store.load(Voiceprint.userID) == user)
		#expect(store.all().map(\.id) == [Voiceprint.userID, "priya"])

		var again = user
		again.sourceCount = 12
		try store.save(again)
		#expect(store.load(Voiceprint.userID)?.sourceCount == 12)

		try store.delete(Voiceprint.userID)
		#expect(store.load(Voiceprint.userID) == nil)
		#expect(store.all().map(\.id) == ["priya"])
		try store.delete(Voiceprint.userID)
	}

	@Test
	func rejectsAnotherEmbedder() throws {
		let store = Self.temporaryStore()
		defer { try? FileManager.default.removeItem(at: store.directory) }
		var voiceprint = Vectors.voiceprint()
		voiceprint.embedder = "campplus"
		try store.save(voiceprint)
		#expect(store.load(Voiceprint.userID) == nil)
		#expect(store.all().isEmpty)
	}

	@Test
	func rejectsTheWrongLength() throws {
		let store = Self.temporaryStore()
		defer { try? FileManager.default.removeItem(at: store.directory) }
		try store.save(Vectors.voiceprint(embedding: [Float](repeating: 0.1, count: 192)))
		#expect(store.load(Voiceprint.userID) == nil)
	}

	@Test
	func normalizedMeanIsUnitLength() {
		let mean = Voiceprint.normalizedMean([Vectors.axis(0), Vectors.mix(3, Vectors.axis(0), 4, Vectors.axis(1))])
		#expect(abs(Vectors.norm(mean) - 1) < 1e-5)
		#expect(Voiceprint.cosine(Vectors.axis(0), Vectors.axis(1)) == 0)
		#expect(Voiceprint.cosine(Vectors.axis(0), [1, 0]) == 0)
		#expect(abs(Voiceprint.cosine([2, 0], [3, 3]) - 0.70710677) < 1e-6)
	}
}

struct SpeakerRegistryTests {
	static let user = Vectors.axis(0)

	/// A unit vector at cosine `score` with the user, in the plane of axes 0 and `axis`.
	static func atScore(_ score: Float, axis: Int = 1) -> [Float] {
		Vectors.mix(score, user, (1 - score * score).squareRoot(), Vectors.axis(axis))
	}

	@Test
	func theUserIsSpeakerOneAndOthersAreNumberedInOrder() {
		var registry = SpeakerRegistry(voiceprints: [Vectors.voiceprint()])
		#expect(registry.label(1) == "You")
		#expect(registry.speakerCount == 0)

		#expect(registry.assign(Self.atScore(0.61), seconds: 4) == 1)
		#expect(registry.assign(Self.atScore(0.24), seconds: 3) == 2)
		#expect(registry.label(2) == "Speaker 2")
		#expect(registry.speakerCount == 2)
		#expect(registry.speaker(1)?.turns == 1)
		#expect(registry.speaker(1)?.seconds == 4)
	}

	@Test
	func anotherSpeakersCentroidMovesAndStaysUnitLength() throws {
		var registry = SpeakerRegistry(voiceprints: [Vectors.voiceprint()])
		let second = Self.atScore(0.24)
		#expect(registry.assign(second, seconds: 3) == 2)
		// 0.9 against speaker 2, 0.216 against the user.
		let later = Vectors.mix(0.9, second, Float(0.19).squareRoot(), Vectors.axis(2))
		#expect(registry.assign(later, seconds: 3) == 2)
		let centroid = try #require(registry.speaker(2)?.embedding)
		#expect(centroid != second)
		#expect(abs(Vectors.norm(centroid) - 1) < 1e-4)
		#expect(registry.speaker(2)?.turns == 2)
		#expect(registry.speakerCount == 1)
	}

	@Test
	func theUsersCentroidNeverMoves() {
		var registry = SpeakerRegistry(voiceprints: [Vectors.voiceprint()])
		let before = registry.speaker(1)?.embedding
		for score in [Float(0.95), 0.61, 0.45, 0.41, 0.8] {
			#expect(registry.assign(Self.atScore(score, axis: 3), seconds: 2) == 1)
		}
		#expect(registry.speaker(1)?.embedding == before)
	}

	@Test
	func aVoiceprintMatchWinsOverACloserUnnamedSpeaker() {
		var registry = SpeakerRegistry(voiceprints: [Vectors.voiceprint()])
		let second = Self.atScore(0.24)
		#expect(registry.assign(second, seconds: 3) == 2)
		// 0.45 against the user (over the 0.4 cutoff), 0.3 against speaker 2.
		let a = (0.3 - 0.45 * 0.24) / (1 - 0.24 * 0.24).squareRoot()
		let b = (1 - 0.45 * 0.45 - a * a).squareRoot()
		let vector = (0 ..< Voiceprint.dimensions).map { index -> Float in
			switch index {
			case 0: 0.45
			case 1: Float(a)
			case 4: Float(b)
			default: 0
			}
		}
		#expect(abs(Voiceprint.cosine(vector, Self.user) - 0.45) < 1e-4)
		#expect(abs(Voiceprint.cosine(vector, second) - 0.3) < 1e-4)
		#expect(registry.assign(vector, seconds: 2) == 1)
	}

	@Test
	func withoutAVoiceprintTheFirstVoiceIsSpeakerOne() {
		var registry = SpeakerRegistry()
		#expect(registry.assign(Vectors.axis(5), seconds: 2) == 1)
		#expect(registry.label(1) == "Speaker 1")
		#expect(registry.transcriptLabels == nil)
	}

	@Test
	func aShortTurnNeverOpensASpeaker() {
		var registry = SpeakerRegistry(voiceprints: [Vectors.voiceprint()])
		#expect(registry.assign(Vectors.axis(1), seconds: 5) == 2)
		#expect(registry.assign(Vectors.axis(2), seconds: 5) == 3)
		let centroid = registry.speaker(3)?.embedding

		// 0.3 against speaker 3: under the same-speaker bar, over the floor. Speaker 3, centroid unmoved.
		let nearThree = Vectors.mix(0.3, Vectors.axis(2), Float(1 - 0.09).squareRoot(), Vectors.axis(7))
		#expect(registry.assign(nearThree, seconds: 2.9, neighbour: 2) == 3)
		#expect(registry.speaker(3)?.embedding == centroid)
		#expect(registry.speaker(3)?.turns == 2)
		#expect(registry.speaker(3)?.seconds == 7.9)

		// Close to no one: the neighbouring turn's speaker; with no neighbour, a new speaker after all.
		#expect(registry.assign(Vectors.axis(8), seconds: 1.3, neighbour: 2) == 2)
		#expect(registry.assign(Vectors.axis(9), seconds: 1.3) == 4)
		// 3 s or more of speech opens a speaker as before.
		#expect(registry.assign(Vectors.axis(10), seconds: 3, neighbour: 2) == 5)
		#expect(registry.speakerCount == 4)
		#expect(registry.speaker(1)?.turns == 0)
	}

	@Test
	func roundTripsThroughJSON() throws {
		var registry = SpeakerRegistry(voiceprints: [Vectors.voiceprint()])
		_ = registry.assign(Self.atScore(0.7), seconds: 5)
		_ = registry.assign(Self.atScore(0.1), seconds: 2.5)
		let data = try JSONEncoder().encode(registry)
		#expect(try JSONDecoder().decode(SpeakerRegistry.self, from: data) == registry)
	}

	@Test
	func savedInTheSessionFolder() throws {
		let folder = NotesSessionFolder(FileManager.default.temporaryDirectory.appending(component: "notes-\(UUID().uuidString)"))
		try folder.createDirectories()
		defer { try? FileManager.default.removeItem(at: folder.url) }
		#expect(folder.loadSpeakers() == nil)
		var registry = SpeakerRegistry(voiceprints: [Vectors.voiceprint()])
		_ = registry.assign(Self.atScore(0.1), seconds: 2)
		try folder.saveSpeakers(registry)
		#expect(folder.loadSpeakers() == registry)
	}
}

struct NotesTurnsTests {
	/// 100 samples a second keeps the ranges readable: 1 s = 100, the 0.5 s speech minimum = 50.
	static let rate = 100

	static func segment(_ speaker: String, _ range: Range<Int>, _ axis: Int = 0) -> SpeakerSegment {
		SpeakerSegment(localSpeaker: speaker, range: range, embedding: Vectors.axis(axis))
	}

	static func turns(_ segments: [SpeakerSegment], speech: [Range<Int>]? = nil) -> [NotesTurn] {
		NotesTurns.turns(from: segments, speech: speech ?? segments.map(\.range), sampleRate: rate)
	}

	@Test
	func joinsOneSpeakersSegmentsAcrossShortGaps() {
		let turns = Self.turns([Self.segment("A", 350 ..< 600), Self.segment("A", 0 ..< 300)])
		#expect(turns.map(\.range) == [0 ..< 600])
		#expect(turns.first?.speech == [0 ..< 300, 350 ..< 600])
	}

	@Test
	func aGapOfASecondOrMoreStartsANewTurn() {
		let turns = Self.turns([Self.segment("A", 0 ..< 300), Self.segment("A", 400 ..< 600)])
		#expect(turns.map(\.range) == [0 ..< 350, 350 ..< 600])
	}

	@Test
	func aTurnStopsGrowingAtThirtySeconds() {
		let turns = Self.turns([Self.segment("A", 0 ..< 2_000), Self.segment("A", 2_050 ..< 3_200)])
		#expect(turns.count == 2)
		#expect(turns.allSatisfy { $0.localSpeaker == "A" })
	}

	@Test
	func eachSpeakerGetsTheirOwnTurnAndTheMeanOfTheirSegments() {
		let turns = Self.turns([
			Self.segment("A", 0 ..< 200, 0), Self.segment("A", 250 ..< 400, 1), Self.segment("B", 400 ..< 700, 2),
		])
		#expect(turns.map(\.localSpeaker) == ["A", "B"])
		let half = Float(0.5).squareRoot()
		#expect(abs(turns[0].embedding[0] - half) < 1e-5 && abs(turns[0].embedding[1] - half) < 1e-5)
		#expect(turns[1].embedding == Vectors.axis(2))
	}

	@Test
	func aShortTurnJoinsThePreviousOneAndTakesItsSpeaker() {
		let turns = Self.turns([Self.segment("A", 0 ..< 500), Self.segment("B", 500 ..< 560, 1), Self.segment("C", 600 ..< 1_200, 2)])
		#expect(turns.map(\.localSpeaker) == ["A", "C"])
		#expect(turns.map(\.range) == [0 ..< 580, 580 ..< 1_200])
		#expect(turns[0].embedding == Vectors.axis(0))
	}

	@Test
	func aShortFirstTurnJoinsTheNextOne() {
		let turns = Self.turns([Self.segment("B", 0 ..< 50, 1), Self.segment("A", 60 ..< 600)])
		#expect(turns.map(\.localSpeaker) == ["A"])
		#expect(turns.map(\.range) == [0 ..< 600])
	}

	@Test
	func aShortInterruptionDoesntSplitATurn() {
		let turns = Self.turns([Self.segment("A", 0 ..< 500), Self.segment("B", 520 ..< 580, 1), Self.segment("A", 600 ..< 1_000)])
		#expect(turns.map(\.localSpeaker) == ["A"])
		#expect(turns.map(\.range) == [0 ..< 1_000])
	}

	@Test
	func speechIsClippedToTurnsThatMeetHalfwayAcrossGaps() {
		let turns = Self.turns(
			[Self.segment("A", 100 ..< 500), Self.segment("B", 700 ..< 1_200, 1)],
			speech: [50 ..< 520, 650 ..< 1_250]
		)
		#expect(turns.map(\.range) == [50 ..< 600, 600 ..< 1_250])
		#expect(turns.map(\.speech) == [[50 ..< 520], [650 ..< 1_250]])
	}

	@Test
	func speechAcrossATurnBoundaryIsSplitBetweenThem() {
		let turns = Self.turns([Self.segment("A", 0 ..< 500), Self.segment("B", 500 ..< 900, 1)], speech: [0 ..< 900])
		#expect(turns.map(\.speech) == [[0 ..< 500], [500 ..< 900]])
	}

	@Test
	func overlappingTurnsAreMadeDisjoint() {
		let turns = Self.turns([Self.segment("A", 0 ..< 800), Self.segment("B", 600 ..< 1_000, 1)])
		#expect(turns.map(\.range) == [0 ..< 800, 800 ..< 1_000])
	}

	@Test
	func aTurnWithTooLittleSpeechIsDropped() {
		let turns = Self.turns(
			[Self.segment("A", 0 ..< 500), Self.segment("B", 500 ..< 1_000, 1)],
			speech: [0 ..< 30, 500 ..< 900]
		)
		#expect(turns.map(\.localSpeaker) == ["B"])
	}

	@Test
	func twoVoicesAtOnceMarkTheTurnTheyFallIn() {
		// A and B overlap for 2 s (600–800), which ends up inside A's turn.
		let turns = Self.turns([Self.segment("A", 0 ..< 800), Self.segment("B", 600 ..< 1_000, 1)])
		#expect(turns.map(\.overlapping) == [true, false])
		// Under half a second of overlap (or none) doesn't count.
		let brief = Self.turns([Self.segment("A", 0 ..< 520), Self.segment("B", 480 ..< 1_000, 1)])
		#expect(brief.map(\.overlapping) == [false, false])
		// One speaker's segments overlapping each other isn't two voices.
		let same = Self.turns([Self.segment("A", 0 ..< 800), Self.segment("A", 200 ..< 900)])
		#expect(same.map(\.overlapping) == [false])
	}

	@Test
	func aTurnNestedInAnotherFlagsTheOuterOne() {
		let turns = Self.turns([Self.segment("A", 0 ..< 1_000), Self.segment("B", 300 ..< 600, 1)])
		#expect(turns.map(\.localSpeaker) == ["A"])
		#expect(turns.first?.overlapping == true)
	}

	@Test
	func voiceprintWindowsAreTwoSecondsEveryHalfSecond() {
		#expect(SpeakerOverlap.windows(sampleCount: 31_999, sampleRate: 16_000).isEmpty)
		#expect(SpeakerOverlap.windows(sampleCount: 32_000, sampleRate: 16_000) == [0 ..< 32_000])
		#expect(SpeakerOverlap.windows(sampleCount: 48_000, sampleRate: 16_000).map(\.lowerBound) == [0, 8_000, 16_000])
		// One window over 0.4 is a stray hit; two are the user.
		#expect(!SpeakerOverlap.userHeard([0.1, 0.45, 0.3]))
		#expect(!SpeakerOverlap.userHeard([0.4, 0.4]))
		#expect(SpeakerOverlap.userHeard([0.41, 0.1, 0.52]))
	}

	@Test
	func noSegmentsNoTurns() {
		#expect(Self.turns([], speech: [0 ..< 500]).isEmpty)
	}
}

struct NotesTranscriptTurnsTests {
	static func twoSpeakers() -> SpeakerRegistry {
		var registry = SpeakerRegistry(voiceprints: [Vectors.voiceprint()])
		_ = registry.assign(Vectors.axis(0), seconds: 5)
		_ = registry.assign(Vectors.axis(1), seconds: 5)
		return registry
	}

	@Test
	func anOldLineParsesWithoutTurns() throws {
		let transcript = try #require(NotesTranscript.parse(Data("{\"chunk\":0,\"text\":\"Hello there.\"}\n{\"chunk\":1,\"gap\":true}\n".utf8)))
		#expect(transcript.lines.map(\.turns) == [nil, nil])
		#expect(transcript.lines.first?.text == "Hello there.")
	}

	@Test
	func aTurnsLineKeepsThePlainText() throws {
		let line = NotesTranscriptLine(chunk: 3, turns: [
			NotesTranscriptTurn(speaker: 1, text: "Hi there."), NotesTranscriptTurn(speaker: 2, text: "Hello."),
		])
		let data = try NotesTranscript(lines: [line]).encoded()
		#expect(String(decoding: data, as: UTF8.self) ==
			"{\"chunk\":3,\"text\":\"Hi there. Hello.\",\"turns\":[{\"speaker\":1,\"text\":\"Hi there.\"},{\"speaker\":2,\"text\":\"Hello.\"}]}\n")
		#expect(NotesTranscript.parse(data)?.lines == [line])
		#expect(NotesTranscriptLine(chunk: 4, turns: []) == NotesTranscriptLine(chunk: 4, text: ""))
	}

	@Test
	func overlappingIsStoredOnlyWhenTrue() throws {
		let line = NotesTranscriptLine(chunk: 0, turns: [
			NotesTranscriptTurn(speaker: 2, text: "Over you.", overlapping: true), NotesTranscriptTurn(speaker: 1, text: "Me."),
		])
		let data = try NotesTranscript(lines: [line]).encoded()
		#expect(String(decoding: data, as: UTF8.self) ==
			"{\"chunk\":0,\"text\":\"Over you. Me.\",\"turns\":[{\"overlapping\":true,\"speaker\":2,\"text\":\"Over you.\"},{\"speaker\":1,\"text\":\"Me.\"}]}\n")
		let parsed = try #require(NotesTranscript.parse(data))
		#expect(parsed.lines == [line])
		#expect(parsed.lines[0].turns?.map(\.isOverlapping) == [true, false])
	}

	@Test
	func speakerParagraphsFollowTheLabelledParagraphs() {
		let transcript = NotesTranscript(lines: [
			NotesTranscriptLine(chunk: 0, turns: [
				NotesTranscriptTurn(speaker: 2, text: " Posters are A0. ", overlapping: true), NotesTranscriptTurn(speaker: 1, text: "Laptops?"),
			]),
			.gap(chunk: 1),
			NotesTranscriptLine(chunk: 2, text: ""),
			NotesTranscriptLine(chunk: 3, text: "Unlabelled."),
		])
		#expect(transcript.speakerParagraphs == [
			NotesTranscriptParagraph(speaker: 2, text: "Posters are A0.", overlapping: true),
			NotesTranscriptParagraph(speaker: 1, text: "Laptops?"),
			NotesTranscriptParagraph(speaker: nil, text: NotesTranscript.gapMarker),
			NotesTranscriptParagraph(speaker: nil, text: "Unlabelled."),
		])
		#expect(transcript.speakerParagraphs.count == transcript.paragraphs(labels: Self.twoSpeakers().transcriptLabels)
			.components(separatedBy: "\n\n").count)
	}

	@Test
	func labelledParagraphsRoundTripThroughAnEdit() {
		let registry = Self.twoSpeakers()
		let transcript = NotesTranscript(lines: [
			NotesTranscriptLine(chunk: 0, turns: [
				NotesTranscriptTurn(speaker: 1, text: "Any questions?"), NotesTranscriptTurn(speaker: 2, text: "Yes, about the poster."),
			]),
			.gap(chunk: 1),
			NotesTranscriptLine(chunk: 2, text: "An older unlabelled chunk."),
			NotesTranscriptLine(chunk: 3, turns: [NotesTranscriptTurn(speaker: 1, text: "Thanks.")]),
		])
		let paragraphs = transcript.paragraphs(labels: registry.transcriptLabels)
		#expect(paragraphs == """
		You: Any questions?

		Speaker 2: Yes, about the poster.

		\(NotesTranscript.gapMarker)

		An older unlabelled chunk.

		You: Thanks.
		""")
		let edited = transcript.edited(paragraphs, registry: registry)
		#expect(edited.paragraphs(labels: registry.transcriptLabels) == paragraphs)
		#expect(edited.lines.map(\.chunk) == [0, 1, 2, 3, 4])
		#expect(edited.lines[1].turns == [NotesTranscriptTurn(speaker: 2, text: "Yes, about the poster.")])
		#expect(edited.lines[3].turns == nil)
		// An unknown label stays part of the text.
		let unknown = transcript.edited("Speaker 9: Hello.\n\nNote: this is text.", registry: registry)
		#expect(unknown.lines.map(\.turns) == [nil, nil])
		#expect(unknown.lines.first?.text == "Speaker 9: Hello.")
	}

	@Test
	func labelledTextPutsEachTurnOnItsOwnLine() {
		let registry = Self.twoSpeakers()
		let lines = [
			NotesTranscriptLine(chunk: 0, turns: [
				NotesTranscriptTurn(speaker: 2, text: "What's next?"), NotesTranscriptTurn(speaker: 1, text: "The demo."),
			]),
			NotesTranscriptLine(chunk: 1, text: "Plain."),
		]
		#expect(NotesTranscript.text(of: lines, labels: registry.transcriptLabels) == "Speaker 2: What's next?\nYou: The demo.\nPlain.")
		#expect(NotesTranscript.text(of: lines) == "What's next? The demo. Plain.")
	}

	@Test
	func oneSpeakerShowsNoLabels() {
		var registry = SpeakerRegistry(voiceprints: [Vectors.voiceprint()])
		_ = registry.assign(Vectors.axis(0), seconds: 5)
		let transcript = NotesTranscript(lines: [
			NotesTranscriptLine(chunk: 0, turns: [NotesTranscriptTurn(speaker: 1, text: "Just me.")]),
			NotesTranscriptLine(chunk: 1, turns: [NotesTranscriptTurn(speaker: 1, text: "Still me.")]),
		])
		#expect(registry.transcriptLabels == nil)
		#expect(transcript.paragraphs(labels: registry.transcriptLabels) == "Just me.\n\nStill me.")
		#expect(transcript.paragraphs == "Just me.\n\nStill me.")
		#expect(NotesTranscript.text(of: transcript.lines, labels: registry.transcriptLabels) == "Just me. Still me.")
	}

	@Test
	func thePromptMentionsSpeakersOnlyWhenLabelled() {
		let plain = NotesPrompts.pieceMessages("text", part: 1, of: 1)[0].content
		let labelled = NotesPrompts.pieceMessages("You: text", part: 1, of: 1, speakerLabels: true)[0].content
		#expect(!plain.contains("Speaker N:"))
		#expect(labelled.contains("Lines starting with \"You:\" are the person who recorded"))
	}

	@Test
	func speakerLabelsAreOnByDefault() throws {
		#expect(HexSettings().notesSpeakerLabels)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: Data("{}".utf8))
		#expect(decoded.notesSpeakerLabels)
	}
}
