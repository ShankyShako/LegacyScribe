import AppKit
import ComposableArchitecture
import HexCore
import SwiftUI
import XCTest

@testable import Hex

/// Notes trimming (DESIGN.md "Notes trimming"): the real Transcript tab in trim mode, rendered to
/// `/tmp/trim-built.png` for a look (three speakers, a selection, a left-out row, the stale banner, the
/// timeline strip and the selection bar), plus the selection reducer and the row grouping.
@MainActor
final class NotesTrimSnapshotTests: XCTestCase {
	private static let sessionID = "2026-10-16-104200"

	/// Chunk 0 is a stretch to leave out; the rest is the mock-up's conversation.
	private static func transcript() -> NotesTranscript {
		func line(_ chunk: Int, _ seconds: Double, _ turns: [(Int, String)]) -> NotesTranscriptLine {
			var line = NotesTranscriptLine(chunk: chunk, turns: turns.map { NotesTranscriptTurn(speaker: $0.0, text: $0.1) })
			line.seconds = seconds
			return line
		}
		return NotesTranscript(lines: [
			line(0, 25, [(3, "Anyway, did anyone watch the game last night? It went to overtime, apparently.")]),
			line(1, 25, [(2, "So the consent form goes to the IRB on Monday. Nadia owns the data-sharing section.")]),
			line(2, 25, [
				(1, "Okay, I'll send her the template tonight. By the way, how was the trip? Did you end up going to Denver?"),
				(2, "We did, my sister's wedding was on Saturday. The flight back was a mess, four hours on the tarmac. But the food was great."),
			]),
			line(3, 25, [(3, "Sorry, back to the budget for a second. We're about eight thousand short on the scanner hours.")]),
		])
	}

	private static func paragraph(_ speaker: Int) -> NotesSpeakerParagraph {
		NotesSpeakerParagraph(
			speaker: speaker, label: speaker == 1 ? "You" : "Speaker \(speaker)", isUser: speaker == 1, text: "", overlapping: false, seconds: 300
		)
	}

	private static func content(trims: NotesTrims) -> NotesContent {
		let transcript = transcript()
		let sentences = NotesTrims.sentences(of: transcript)
		let timeline = NotesTimeline.build(transcript, trims: trims, sessionSeconds: 100)
		return NotesContent(
			notes: "- Notes written before the trim.",
			transcript: NotesTranscript(lines: trims.applied(to: transcript)).paragraphs,
			speakerCount: 3,
			speakerParagraphs: [paragraph(2)],
			fullTranscript: transcript.paragraphs,
			sentences: zip(sentences, timeline).map { sentence, placed in
				NotesSentenceItem(
					point: sentence.point, text: sentence.text, startsParagraph: sentence.point.sentence == 0,
					paragraph: paragraph(sentence.speaker ?? 2), start: placed.start, end: placed.end, trimIndex: placed.trimIndex
				)
			},
			trims: trims.trims.enumerated().map { index, trim in
				let span = timeline.filter { $0.trimIndex == index }
				return NotesTrimRow(
					index: index, start: span.first?.start ?? 0, end: span.last?.end ?? 0,
					gist: NotesTrims.gist(of: trim, in: sentences)
				)
			},
			notesStale: true,
			sessionSeconds: 100
		)
	}

	private static func leftOutOne() -> NotesTrims {
		var trims = NotesTrims()
		trims.leaveOut(
			from: NotesTrimPoint(chunk: 0, turn: 0, sentence: 0), to: NotesTrimPoint(chunk: 0, turn: 0, sentence: 1), in: transcript()
		)
		return trims
	}

	private static func summary() -> NotesSessionSummary {
		var session = NotesSession(id: sessionID, startedAt: Date(timeIntervalSince1970: 1_792_140_120), stage: .done)
		session.endedAt = session.startedAt.addingTimeInterval(100)
		return NotesSessionSummary(
			session: session, transcribedChunks: 4, pendingChunks: 0, gaps: 0, words: 2_310, approximateSeconds: 100,
			speakerCount: 3, notesStale: true
		)
	}

	private func makeState() -> NotesFeature.State {
		var state = NotesFeature.State(
			hexSettings: Shared(value: HexSettings()), transcriptionHistory: Shared(value: TranscriptionHistory())
		)
		state.sessions = [Self.summary()]
		state.selectedID = Self.sessionID
		state.content = Self.content(trims: Self.leftOutOne())
		state.showing = .transcript
		return state
	}

	// MARK: - Look

	func testTrimModeRenders() throws {
		var state = makeState()
		state.trimming = true
		state.trimSelection = .init(NotesTrimPoint(chunk: 2, turn: 0, sentence: 1), NotesTrimPoint(chunk: 2, turn: 1, sentence: 2))
		let store = Store(initialState: state) { NotesFeature() }
		let hosting = NSHostingView(rootView: NotesSessionDetail(store: store, summary: Self.summary())
			.frame(width: 620, height: 640)
			.background(Color(nsColor: .windowBackgroundColor))
			.environment(\.colorScheme, .light))
		hosting.appearance = NSAppearance(named: .aqua)
		hosting.frame.size = hosting.fittingSize
		let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
		window.contentView = hosting
		hosting.layoutSubtreeIfNeeded()
		// Frames are gathered after the first layout pass.
		RunLoop.main.run(until: Date().addingTimeInterval(0.3))
		hosting.layoutSubtreeIfNeeded()
		let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
		hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
		let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
		try data.write(to: URL(fileURLWithPath: "/tmp/trim-built.png"))
	}

	// MARK: - Rows

	func testALeftOutStretchIsOneRowAndTheChipGoesOnTheFirstSegment() {
		var trims = NotesTrims()
		let transcript = Self.transcript()
		// Chunk 2's first turn loses its second sentence: the paragraph is split around the stretch.
		trims.leaveOut(
			from: NotesTrimPoint(chunk: 2, turn: 0, sentence: 1), to: NotesTrimPoint(chunk: 2, turn: 0, sentence: 1), in: transcript
		)
		let content = Self.content(trims: trims)
		let blocks = NotesSpeakerTranscript.blocks(content.sentences, trims: content.trims)
		let shown = blocks.map { block -> String in
			switch block {
			case let .text(text): "\(text.showsChip ? "chip " : "")\(text.sentences.count)"
			case let .leftOut(row): "out \(row.index)"
			}
		}
		// chunk 0, chunk 1, "Okay…" (chip), the stretch, the rest of that turn (no chip: it continues the
		// paragraph), speaker 2's turn, chunk 3.
		XCTAssertEqual(shown, ["chip 2", "chip 2", "chip 1", "out 0", "1", "chip 3", "chip 2"])
	}

	func testAParagraphThatOpensLeftOutKeepsItsChip() {
		var trims = NotesTrims()
		trims.leaveOut(
			from: NotesTrimPoint(chunk: 2, turn: 0, sentence: 2), to: NotesTrimPoint(chunk: 2, turn: 1, sentence: 0), in: Self.transcript()
		)
		let content = Self.content(trims: trims)
		let blocks = NotesSpeakerTranscript.blocks(content.sentences, trims: content.trims)
		guard case let .text(tail)? = blocks.dropLast().last else { return XCTFail("expected the tail of speaker 2's turn") }
		XCTAssertTrue(tail.showsChip, "its first sentence is left out, so the tail carries the chip")
		XCTAssertEqual(tail.sentences.count, 2)
	}

	// MARK: - Selection

	func testSelectionIsOrderedAndShiftClickExtendsFromTheAnchor() async {
		var state = makeState()
		state.trimming = true
		let store = TestStore(initialState: state) { NotesFeature() }
		store.exhaustivity = .off
		let a = NotesTrimPoint(chunk: 1, turn: 0, sentence: 0), b = NotesTrimPoint(chunk: 3, turn: 0, sentence: 1)
		await store.send(.selectSentences(from: b, to: a))
		XCTAssertEqual(store.state.trimSelection?.start, a)
		XCTAssertEqual(store.state.trimSelection?.end, b)
		let c = NotesTrimPoint(chunk: 2, turn: 0, sentence: 0)
		await store.send(.selectSentences(from: c, to: c))
		await store.send(.extendSelection(to: a))
		XCTAssertEqual(store.state.trimSelection?.start, a)
		XCTAssertEqual(store.state.trimSelection?.end, c)
		// Dragged backwards from b, then shift-clicked past it: the selection grows from b, not from its top.
		await store.send(.selectSentences(from: b, to: c))
		let d = NotesTrimPoint(chunk: 4, turn: 0, sentence: 0)
		await store.send(.extendSelection(to: d))
		XCTAssertEqual(store.state.trimSelection?.start, b)
		XCTAssertEqual(store.state.trimSelection?.end, d)
	}

	func testLeaveOutSendsTheOrderedRangeAndClearsTheSelection() async {
		var state = makeState()
		state.trimming = true
		let a = NotesTrimPoint(chunk: 1, turn: 0, sentence: 1), b = NotesTrimPoint(chunk: 2, turn: 0, sentence: 0)
		state.trimSelection = .init(b, a)
		let calls = LockIsolated<[String]>([])
		let store = TestStore(initialState: state) { NotesFeature() } withDependencies: {
			$0.notes.leaveOut = { id, from, to in calls.withValue { $0.append("\(id) \(from) \(to)") } }
			$0.notes.list = { [] }
			$0.notes.content = { _ in NotesContent(notes: nil, transcript: "") }
		}
		store.exhaustivity = .off
		await store.send(.leaveOutSelection)
		XCTAssertNil(store.state.trimSelection)
		await store.receive(\.reload)
		await store.finish()
		XCTAssertEqual(calls.value, ["\(Self.sessionID) \(a) \(b)"])
	}

	func testEditingAndSelectingASessionLeaveTrimMode() async {
		var state = makeState()
		state.trimming = true
		state.trimSelection = .init(NotesTrimPoint(chunk: 1, turn: 0, sentence: 0), NotesTrimPoint(chunk: 1, turn: 0, sentence: 1))
		let store = TestStore(initialState: state) { NotesFeature() }
		store.exhaustivity = .off
		await store.send(.editTranscript)
		XCTAssertFalse(store.state.trimming)
		XCTAssertNil(store.state.trimSelection)
		XCTAssertEqual(store.state.transcriptDraft, Self.content(trims: Self.leftOutOne()).fullTranscript, "Edit shows the left-out words too")
		XCTAssertTrue(store.state.transcriptDraft?.contains("Anyway, did anyone watch the game") == true)
	}

	func testTheBannerNamesTheStretches() {
		XCTAssertEqual(NotesSessionDetail.staleText(1), "1 stretch left out. The notes still include it.")
		XCTAssertEqual(NotesSessionDetail.staleText(3), "3 stretches left out. The notes still include them.")
	}
}
