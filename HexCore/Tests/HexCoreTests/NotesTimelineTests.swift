@testable import HexCore
import Testing

struct NotesTimelineTests {
	static func line(_ chunk: Int, _ text: String, seconds: Double?) -> NotesTranscriptLine {
		var line = NotesTranscriptLine(chunk: chunk, text: text)
		line.seconds = seconds
		return line
	}

	@Test func aChunkWithoutALengthTakesWhatIsLeft() {
		let transcript = NotesTranscript(lines: [
			Self.line(0, "One two.", seconds: 25), Self.line(1, "Three four.", seconds: nil), Self.line(2, "Five six.", seconds: 25),
		])
		let sentences = NotesTimeline.build(transcript, trims: NotesTrims(), sessionSeconds: 80)
		#expect(sentences.map(\.start) == [0, 25, 55])
		#expect(sentences.map(\.end) == [25, 55, 80])
	}

	@Test func unknownChunksShareEvenlyAtLeastASecondEach() {
		let transcript = NotesTranscript(lines: [
			Self.line(0, "A.", seconds: nil), Self.line(1, "B.", seconds: nil),
		])
		#expect(NotesTimeline.build(transcript, trims: NotesTrims(), sessionSeconds: 100).map(\.end) == [50, 100])
		#expect(NotesTimeline.build(transcript, trims: NotesTrims(), sessionSeconds: 0.5).map(\.end) == [1, 2])
		#expect(NotesTimeline.build(transcript, trims: NotesTrims(), sessionSeconds: nil).map(\.end) == [25, 50])
	}

	@Test func sentencesShareAChunkByWords() {
		let transcript = NotesTranscript(lines: [Self.line(0, "One two three. Four.", seconds: 20)])
		let sentences = NotesTimeline.build(transcript, trims: NotesTrims(), sessionSeconds: nil)
		#expect(sentences.map(\.start) == [0, 15])
		#expect(sentences.map(\.end) == [15, 20])
	}

	@Test func trimmedSentencesCarryTheirTrim() {
		let transcript = NotesTranscript(lines: [Self.line(0, "A b. C d.", seconds: 10)])
		var trims = NotesTrims()
		trims.leaveOut(from: NotesTrimPoint(chunk: 0, turn: 0, sentence: 1), to: NotesTrimPoint(chunk: 0, turn: 0, sentence: 1), in: transcript)
		#expect(NotesTimeline.build(transcript, trims: trims, sessionSeconds: nil).map(\.trimIndex) == [nil, 0])
	}

	@Test func handlesSnapToTheNearestSentenceEdge() {
		let transcript = NotesTranscript(lines: [
			Self.line(0, "One.", seconds: 25), Self.line(1, "Two.", seconds: 25), Self.line(2, "Three.", seconds: 25),
		])
		let sentences = NotesTimeline.build(transcript, trims: NotesTrims(), sessionSeconds: nil)
		#expect(NotesTimeline.nearestStart(to: 27, in: sentences) == NotesTrimPoint(chunk: 1, turn: 0, sentence: 0))
		#expect(NotesTimeline.nearestEnd(to: 27, in: sentences) == NotesTrimPoint(chunk: 0, turn: 0, sentence: 0))
		#expect(NotesTimeline.nearestEnd(to: 70, in: sentences) == NotesTrimPoint(chunk: 2, turn: 0, sentence: 0))
		#expect(NotesTimeline.nearestStart(to: 1, in: []) == nil)
	}

	@Test func clockFormats() {
		#expect(NotesTimeline.clock(0) == "0:00")
		#expect(NotesTimeline.clock(380) == "6:20")
		#expect(NotesTimeline.clock(525) == "8:45")
		#expect(NotesTimeline.clock(3_725) == "1:02:05")
		#expect(NotesTimeline.clock(-4) == "0:00")
	}
}
