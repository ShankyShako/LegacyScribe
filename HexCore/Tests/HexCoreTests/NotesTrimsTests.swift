import Foundation
@testable import HexCore
import Testing

struct NotesTrimsTests {
	/// Chunk 0: one turn of speaker 2 (two sentences), chunk 1: a gap, chunk 2: speaker 1 then speaker 3.
	static let transcript = NotesTranscript(lines: [
		NotesTranscriptLine(chunk: 0, turns: [NotesTranscriptTurn(speaker: 2, text: "One a. One b.")]),
		.gap(chunk: 1),
		NotesTranscriptLine(chunk: 2, turns: [
			NotesTranscriptTurn(speaker: 1, text: "Two a. Two b. Two c."),
			NotesTranscriptTurn(speaker: 3, text: "Three a. Three b.", overlapping: true),
		]),
		NotesTranscriptLine(chunk: 3, text: "Four a. Four b."),
	])

	static func point(_ chunk: Int, _ turn: Int = 0, _ sentence: Int = 0) -> NotesTrimPoint {
		NotesTrimPoint(chunk: chunk, turn: turn, sentence: sentence)
	}

	@Test func sentencesFollowTheTranscript() {
		let sentences = NotesTrims.sentences(of: Self.transcript)
		#expect(sentences.map(\.text) == [
			"One a.", "One b.", NotesTranscript.gapMarker, "Two a.", "Two b.", "Two c.", "Three a.", "Three b.", "Four a.", "Four b.",
		])
		#expect(sentences[2].isGap && sentences[2].wordCount == 10 && sentences[2].speaker == nil)
		#expect(sentences[6].point == Self.point(2, 1, 0) && sentences[6].speaker == 3)
		#expect(sentences[8].point == Self.point(3, 0, 0) && sentences[8].speaker == nil)
	}

	@Test func leavingOutFromMidTurnToMidTurnKeepsTheHeadAndTheTail() {
		var trims = NotesTrims()
		trims.leaveOut(from: Self.point(2, 0, 1), to: Self.point(2, 1, 0), in: Self.transcript)
		#expect(trims.version == 1)
		#expect(trims.trims.count == 1)
		#expect(trims.trims[0].first == "Two b." && trims.trims[0].last == "Three a.")
		let applied = trims.applied(to: Self.transcript)
		let line = applied.first { $0.chunk == 2 }
		#expect(line?.turns?.map(\.text) == ["Two a.", "Three b."])
		#expect(line?.turns?[1].overlapping == true)
		#expect(line?.text == "Two a. Three b.")
		#expect(applied.count == 4)
	}

	@Test func theEndsMayComeInEitherOrder() {
		var a = NotesTrims(), b = NotesTrims()
		a.leaveOut(from: Self.point(0, 0, 1), to: Self.point(2, 0, 0), in: Self.transcript)
		b.leaveOut(from: Self.point(2, 0, 0), to: Self.point(0, 0, 1), in: Self.transcript)
		#expect(a == b)
	}

	@Test func anOverlappingTrimMergesAndBringingBackEmptiesIt() {
		var trims = NotesTrims()
		trims.leaveOut(from: Self.point(0, 0, 0), to: Self.point(0, 0, 1), in: Self.transcript)
		trims.leaveOut(from: Self.point(0, 0, 1), to: Self.point(2, 0, 0), in: Self.transcript)
		#expect(trims.trims.count == 1)
		#expect(trims.version == 2)
		#expect(trims.trims[0].start == Self.point(0, 0, 0) && trims.trims[0].end == Self.point(2, 0, 0))
		trims.bringBack(at: 0)
		#expect(trims.trims.isEmpty)
		#expect(trims.version == 3)
		trims.bringBack(at: 4)
		#expect(trims.version == 3)
	}

	@Test func aTrimNextToAnotherMergesWithIt() {
		var trims = NotesTrims()
		trims.leaveOut(from: Self.point(0, 0, 0), to: Self.point(0, 0, 0), in: Self.transcript)
		trims.leaveOut(from: Self.point(0, 0, 1), to: Self.point(0, 0, 1), in: Self.transcript)
		#expect(trims.trims.count == 1)
		trims.leaveOut(from: Self.point(3, 0, 1), to: Self.point(3, 0, 1), in: Self.transcript)
		#expect(trims.trims.count == 2)
		#expect(trims.trimIndex(containing: Self.point(0, 0, 1)) == 0)
		#expect(trims.trimIndex(containing: Self.point(2, 0, 0)) == nil)
		#expect(trims.trimIndex(containing: Self.point(3, 0, 1)) == 1)
	}

	@Test func aCoveredGapAndAnEmptiedTurnDisappear() {
		var trims = NotesTrims()
		// From the first chunk's last sentence through the whole of the first turn of chunk 2.
		trims.leaveOut(from: Self.point(0, 0, 1), to: Self.point(2, 0, 2), in: Self.transcript)
		let applied = trims.applied(to: Self.transcript)
		#expect(applied.map(\.chunk) == [0, 2, 3])
		#expect(applied[0].turns?.map(\.text) == ["One a."])
		#expect(applied[1].turns?.map(\.speaker) == [3])
		#expect(applied.allSatisfy { !$0.isGap })
		// A line with every turn left out goes too.
		var all = NotesTrims()
		all.leaveOut(from: Self.point(2, 0, 0), to: Self.point(2, 1, 1), in: Self.transcript)
		#expect(all.applied(to: Self.transcript).map(\.chunk) == [0, 1, 3])
	}

	@Test func anUnlabelledLineLosesItsSentences() {
		var trims = NotesTrims()
		trims.leaveOut(from: Self.point(3, 0, 0), to: Self.point(3, 0, 0), in: Self.transcript)
		#expect(trims.applied(to: Self.transcript).last?.text == "Four b.")
		trims.leaveOut(from: Self.point(3, 0, 1), to: Self.point(3, 0, 1), in: Self.transcript)
		#expect(trims.applied(to: Self.transcript).map(\.chunk) == [0, 1, 2])
	}

	@Test func appliedKeepsSecondsAndChunkNumbers() {
		var line = NotesTranscriptLine(chunk: 7, text: "Keep this. Drop this.")
		line.seconds = 24.5
		let transcript = NotesTranscript(lines: [line])
		var trims = NotesTrims()
		trims.leaveOut(from: Self.point(7, 0, 1), to: Self.point(7, 0, 1), in: transcript)
		let applied = trims.applied(to: transcript)
		#expect(applied.first?.chunk == 7 && applied.first?.seconds == 24.5 && applied.first?.text == "Keep this.")
	}

	@Test func noTrimsReturnsTheSameLines() {
		#expect(NotesTrims().applied(to: Self.transcript) == Self.transcript.lines)
	}

	@Test func aPointOutsideTheTranscriptChangesNothing() {
		var trims = NotesTrims()
		trims.leaveOut(from: Self.point(9), to: Self.point(9), in: Self.transcript)
		#expect(trims == NotesTrims())
	}

	@Test func reanchoringFollowsAnInsertedParagraph() {
		var trims = NotesTrims()
		trims.leaveOut(from: Self.point(2, 0, 1), to: Self.point(2, 1, 0), in: Self.transcript)
		var lines = Self.transcript.lines.map { line -> NotesTranscriptLine in
			var moved = line
			moved.chunk += 1
			return moved
		}
		lines.insert(NotesTranscriptLine(chunk: 0, text: "Brand new."), at: 0)
		let edited = NotesTranscript(lines: lines)
		let anchored = trims.reanchored(to: edited)
		#expect(anchored.trims.count == 1)
		#expect(anchored.trims[0].start == Self.point(3, 0, 1) && anchored.trims[0].end == Self.point(3, 1, 0))
		#expect(anchored.version == trims.version + 1)
		// Nothing moved: nothing changes, not even the version.
		#expect(trims.reanchored(to: Self.transcript) == trims)
	}

	@Test func reanchoringDropsATrimWhoseFirstSentenceWasEdited() {
		var trims = NotesTrims()
		trims.leaveOut(from: Self.point(2, 0, 1), to: Self.point(2, 1, 0), in: Self.transcript)
		let edited = NotesTranscript(lines: [
			NotesTranscriptLine(chunk: 2, turns: [NotesTranscriptTurn(speaker: 1, text: "Two a. Two B changed. Two c.")]),
			NotesTranscriptLine(chunk: 3, turns: [NotesTranscriptTurn(speaker: 3, text: "Three a. Three b.")]),
		])
		let anchored = trims.reanchored(to: edited)
		#expect(anchored.trims.isEmpty)
		#expect(anchored.version == trims.version + 1)
	}

	@Test func gistIsTheFirstEightWords() {
		let transcript = NotesTranscript(lines: [
			NotesTranscriptLine(chunk: 0, text: "Anyway did anyone watch the game last night at all? Short one."),
		])
		var trims = NotesTrims()
		trims.leaveOut(from: Self.point(0, 0, 0), to: Self.point(0, 0, 1), in: transcript)
		let sentences = NotesTrims.sentences(of: transcript)
		#expect(NotesTrims.gist(of: trims.trims[0], in: sentences) == "Anyway did anyone watch the game last night…")
		var short = NotesTrims()
		short.leaveOut(from: Self.point(0, 0, 1), to: Self.point(0, 0, 1), in: transcript)
		#expect(NotesTrims.gist(of: short.trims[0], in: sentences) == "Short one.")
	}

	@Test func encodesAndDecodesWithSortedKeys() throws {
		var trims = NotesTrims()
		trims.leaveOut(from: Self.point(2, 0, 1), to: Self.point(2, 1, 0), in: Self.transcript)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		let data = try encoder.encode(trims)
		#expect(try JSONDecoder().decode(NotesTrims.self, from: data) == trims)
		#expect(try encoder.encode(trims) == data)
	}

	@Test func folderRoundTripAndMissingFile() throws {
		let directory = FileManager.default.temporaryDirectory.appending(component: "trims-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let folder = NotesSessionFolder(directory)
		#expect(folder.loadTrims() == NotesTrims())
		var trims = NotesTrims()
		trims.leaveOut(from: Self.point(0, 0, 0), to: Self.point(0, 0, 1), in: Self.transcript)
		try folder.saveTrims(trims)
		#expect(folder.loadTrims() == trims)
		try Data("not json".utf8).write(to: folder.trimsURL)
		#expect(folder.loadTrims() == NotesTrims())
	}

	@Test func staleMeansTheNotesWereWrittenFromAnotherVersion() {
		var session = NotesSession(id: "x", startedAt: Date(), stage: .done)
		#expect(!session.notesStale(trimsVersion: 0))
		#expect(session.notesStale(trimsVersion: 1))
		session.notesTrimsVersion = 1
		#expect(!session.notesStale(trimsVersion: 1))
		session.stage = .noting
		#expect(!session.notesStale(trimsVersion: 3))
	}
}

struct NotesTranscriptSecondsTests {
	@Test func secondsRoundTrip() throws {
		var line = NotesTranscriptLine(chunk: 0, text: "hello")
		line.seconds = 24.75
		let transcript = NotesTranscript(lines: [line, NotesTranscriptLine(chunk: 1, text: "no length")])
		let data = try transcript.encoded()
		let parsed = try #require(NotesTranscript.parse(data))
		#expect(parsed == transcript)
		#expect(parsed.lines[0].seconds == 24.75 && parsed.lines[1].seconds == nil)
		#expect(!String(decoding: data, as: UTF8.self).split(separator: "\n")[1].contains("seconds"))
	}

	@Test func anOldFileHasNoSeconds() throws {
		let old = Data("{\"chunk\":0,\"text\":\"old\"}\n{\"chunk\":1,\"gap\":true}\n".utf8)
		let parsed = try #require(NotesTranscript.parse(old))
		#expect(parsed.lines.map(\.seconds) == [nil, nil])
	}

	@Test func editedCarriesALinesSecondsToTheParagraphTakingItsChunk() {
		var first = NotesTranscriptLine(chunk: 0, text: "First part.")
		first.seconds = 20
		var second = NotesTranscriptLine(chunk: 1, text: "Second part.")
		second.seconds = 30
		let transcript = NotesTranscript(lines: [first, second])
		let edited = transcript.edited("First part.\n\nSecond part.\n\nAdded part.")
		#expect(edited.lines.map(\.seconds) == [20, 30, nil])
	}
}
