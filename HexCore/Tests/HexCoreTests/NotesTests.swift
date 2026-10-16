import Foundation
@testable import HexCore
import Testing

struct NotesChunkerTests {
	static let rate = NotesChunker.sampleRate

	/// Loud audio with a 0.5 s pause starting at `pauseAt` seconds.
	static func speech(seconds: Double, pauseAt: Double) -> [Float] {
		let count = Int(seconds * Double(rate))
		let pause = Int(pauseAt * Double(rate)) ..< Int((pauseAt + 0.5) * Double(rate))
		return (0 ..< count).map { pause.contains($0) ? 0 : ($0 % 2 == 0 ? 0.5 : -0.5) }
	}

	@Test
	func cutsAtThePauseAndKeepsEverySample() {
		let samples = Self.speech(seconds: 70, pauseAt: 23)
		var chunker = NotesChunker()
		var chunks: [[Float]] = []
		var offset = 0
		while offset < samples.count {
			let end = min(samples.count, offset + 1_600)
			chunks += chunker.append(Array(samples[offset ..< end]))
			offset = end
		}
		if let tail = chunker.finish() { chunks.append(tail) }

		// The pause covers 23.0–23.5 s; the earliest silent window is centred 50 ms in.
		#expect(chunks.first?.count == 23 * Self.rate + Self.rate / 20)
		#expect(chunks.dropLast().allSatisfy { $0.count >= 20 * Self.rate && $0.count <= 30 * Self.rate })
		#expect(chunks.reduce(0) { $0 + $1.count } == samples.count)
		#expect(Array(chunks.joined()) == samples)
		#expect(chunker.bufferedSeconds == 0)
	}

	@Test
	func oneLargeAppendCanCompleteSeveralChunks() {
		var chunker = NotesChunker()
		let samples = [Float](repeating: 0.5, count: 95 * Self.rate)
		let chunks = chunker.append(samples)
		// No pause anywhere: every window ties and the earliest cut (20.05 s) wins.
		#expect(chunks.map(\.count) == Array(repeating: 20 * Self.rate + Self.rate / 20, count: 4))
		#expect(chunks.reduce(0) { $0 + $1.count } + Int(chunker.bufferedSeconds * Double(Self.rate)) == samples.count)
	}

	@Test
	func finishOnAnEmptyBufferGivesNil() {
		var chunker = NotesChunker()
		let empty = chunker.finish()
		_ = chunker.append([0.1, 0.2])
		let tail = chunker.finish()
		let again = chunker.finish()
		#expect(empty == nil)
		#expect(tail == [0.1, 0.2])
		#expect(again == nil)
	}

	@Test
	func silence() {
		#expect(NotesChunker.isSilent([Float](repeating: 0, count: 16_000)))
		#expect(NotesChunker.isSilent([Float](repeating: 0.001, count: 16_000)))
		var loud = [Float](repeating: 0, count: 16_000)
		for index in 8_000 ..< 9_600 { loud[index] = 0.2 }
		#expect(!NotesChunker.isSilent(loud))
	}

	@Test
	func wavHeaderAndClipping() {
		let data = PCM16WAV.data(samples: [0, 1, -1, 2])
		#expect(data.count == 44 + 8)
		#expect(String(decoding: data[0 ..< 4], as: UTF8.self) == "RIFF")
		#expect(String(decoding: data[8 ..< 16], as: UTF8.self) == "WAVEfmt ")
		let dataSize = data[40 ..< 44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
		#expect(UInt32(littleEndian: dataSize) == 8)
		let pcm = data[44...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map(Int16.init(littleEndian:))
		#expect(pcm == [0, Int16.max, -Int16.max, Int16.max])
	}

	@Test
	func wavReadsBack() {
		let data = PCM16WAV.data(samples: [0, 0.5, -1])
		let samples = PCM16WAV.samples(from: data)
		#expect(samples?.count == 3)
		#expect(abs((samples?[1] ?? 0) - 0.5) < 0.001)
		#expect(samples?[2] == -1)
		#expect(PCM16WAV.samples(from: data.dropLast()) == nil)
		#expect(PCM16WAV.samples(from: Data("RIFF".utf8)) == nil)
	}
}

struct NotesTranscriptTests {
	@Test
	func addIsIdempotentAndSorted() {
		var transcript = NotesTranscript()
		let added = [
			transcript.add(.init(chunk: 2, text: "two")),
			transcript.add(.init(chunk: 0, text: "zero")),
			transcript.add(.init(chunk: 2, text: "again")),
		]
		#expect(added == [true, true, false])
		transcript.add(.gap(chunk: 1))
		transcript.add(.init(chunk: 3, text: ""))
		#expect(transcript.lines.map(\.chunk) == [0, 1, 2, 3])
		#expect(transcript.lastChunk == 3)
		#expect(transcript.gapCount == 1)
		#expect(transcript.text == "zero \(NotesTranscript.gapMarker) two")
	}

	@Test
	func encodeParseRoundTrip() throws {
		let transcript = NotesTranscript(lines: [.init(chunk: 0, text: "a/b \"quoted\"\nnewline"), .gap(chunk: 1)])
		let data = try transcript.encoded()
		#expect(String(decoding: data, as: UTF8.self).contains("{\"chunk\":1,\"gap\":true}\n"))
		#expect(NotesTranscript.parse(data) == transcript)
	}

	@Test
	func tornDataIsRejected() throws {
		let data = try NotesTranscript(lines: [.init(chunk: 0, text: "zero"), .init(chunk: 1, text: "one")]).encoded()
		#expect(NotesTranscript.parse(data.dropLast()) == nil)
		#expect(NotesTranscript.parse(data.dropLast(5)) == nil)
		#expect(NotesTranscript.parse(Data("not json\n".utf8)) == nil)
		#expect(NotesTranscript.parse(Data()) == NotesTranscript())
	}
}

struct NotesTranscriptFileTests {
	let directory: URL
	let file: NotesTranscriptFile

	init() throws {
		directory = FileManager.default.temporaryDirectory.appending(component: "NotesTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		file = NotesTranscriptFile(directory: directory)
	}

	func transcript(through last: Int) -> NotesTranscript {
		NotesTranscript(lines: (0 ... last).map { .init(chunk: $0, text: "chunk \($0)") })
	}

	@Test
	func commitThenLoad() throws {
		#expect(file.load() == NotesTranscript())
		try file.commit(transcript(through: 0))
		try file.commit(transcript(through: 1))
		#expect(file.load() == transcript(through: 1))
		#expect(NotesTranscript.parse(try Data(contentsOf: file.backupURL)) == transcript(through: 0))
		#expect(!FileManager.default.fileExists(atPath: file.newURL.path))
	}

	@Test
	func tornNewFileIsIgnored() throws {
		try file.commit(transcript(through: 1))
		try transcript(through: 2).encoded().dropLast(3).write(to: file.newURL)
		#expect(file.load() == transcript(through: 1))
	}

	@Test
	func crashBetweenTheRenamesKeepsTheNewestFile() throws {
		// Current already moved to .bak, .new not yet renamed.
		try transcript(through: 0).encoded().write(to: file.backupURL)
		try transcript(through: 1).encoded().write(to: file.newURL)
		#expect(file.load() == transcript(through: 1))
	}

	@Test
	func backupIsUsedWhenCurrentIsDamaged() throws {
		try file.commit(transcript(through: 0))
		try file.commit(transcript(through: 1))
		try Data("{\"chunk\":".utf8).write(to: file.currentURL)
		#expect(file.load() == transcript(through: 0))
	}
}

struct NotesSessionTests {
	@Test
	func idSortsByStartTime() {
		let date = Date(timeIntervalSince1970: 1_791_590_400) // 2026-10-10 00:00:00 UTC
		#expect(NotesSession.id(for: date, timeZone: TimeZone(identifier: "UTC")!) == "2026-10-10-000000")
	}

	@Test
	func fileNames() {
		#expect(NotesSessionFolder.chunkIndex(fromName: "00042.wav") == 42)
		#expect(NotesSessionFolder.chunkIndex(fromName: "00042.wav.partial") == nil)
		#expect(NotesSessionFolder.chunkIndex(fromName: ".DS_Store") == nil)
		#expect(NotesSessionFolder.partIndex(fromName: "part-07.md") == 7)
		#expect(NotesSessionFolder.partIndex(fromName: "notes.md") == nil)
		let folder = NotesSessionFolder(URL(filePath: "/tmp/s"))
		#expect(folder.pendingChunkURL(42).lastPathComponent == "00042.wav")
		#expect(folder.partURL(3).lastPathComponent == "part-03.md")
	}

	@Test
	func folderListsChunksAndManifestRoundTrips() throws {
		let url = FileManager.default.temporaryDirectory.appending(component: "NotesSession-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: url) }
		let folder = NotesSessionFolder(url)
		try folder.createDirectories()
		for name in ["00010.wav", "00002.wav", "00011.wav.partial"] {
			try Data().write(to: folder.pendingURL.appending(component: name))
		}
		try Data().write(to: folder.partURL(1))
		#expect(folder.pendingChunks() == [2, 10])
		#expect(folder.failedChunks() == [])
		#expect(folder.savedParts() == [1])

		var session = NotesSession(id: "2026-10-10-120000", startedAt: Date(timeIntervalSince1970: 1_791_633_600))
		session.stage = .noting
		session.notesError = "Ollama not running"
		try folder.saveManifest(session)
		#expect(folder.loadManifest() == session)
	}

	@Test
	func recoveryPlan() {
		let transcript = NotesTranscript(lines: [.init(chunk: 0, text: "a"), .init(chunk: 3, text: "b")])
		#expect(NotesRecovery.plan(stage: .recording, pending: [3, 4, 5], transcript: transcript)
			== .init(queue: [4, 5], alreadyTranscribed: [3], stage: .transcribing))
		#expect(NotesRecovery.plan(stage: .transcribing, pending: [3], transcript: transcript)
			== .init(queue: [], alreadyTranscribed: [3], stage: .noting))
		#expect(NotesRecovery.plan(stage: .noting, pending: [], transcript: transcript).stage == .noting)
		#expect(NotesRecovery.plan(stage: .done, pending: [], transcript: transcript).stage == .done)
	}
}

struct NotesPromptsTests {
	static func line(_ chunk: Int, words: Int) -> NotesTranscriptLine {
		.init(chunk: chunk, text: Array(repeating: "word", count: words).joined(separator: " "))
	}

	@Test
	func piecesSplitAtChunkBoundaries() {
		let lines = (0 ..< 7).map { Self.line($0, words: 500) }
		#expect(NotesPrompts.pieces(lines).map { $0.map(\.chunk) } == [[0, 1, 2], [3, 4, 5], [6]])
	}

	@Test
	func shortTailJoinsThePreviousPiece() {
		let lines = (0 ..< 6).map { Self.line($0, words: 500) } + [Self.line(6, words: 100)]
		#expect(NotesPrompts.pieces(lines).map { $0.map(\.chunk) } == [[0, 1, 2], [3, 4, 5, 6]])
	}

	@Test
	func emptyPiecesAreDropped() {
		#expect(NotesPrompts.pieces([.init(chunk: 0, text: ""), .init(chunk: 1, text: "")]).isEmpty)
		#expect(NotesPrompts.pieces([.gap(chunk: 0)]).count == 1)
	}

	@Test
	func messages() {
		let piece = NotesPrompts.pieceMessages("hello", part: 2, of: 3, vocabulary: ["Ollama", " "])
		#expect(piece.count == 2)
		#expect(piece[0].content.contains("part 2 of 3"))
		#expect(piece[0].content.contains("exactly like this when they occur, including near-misses of them: Ollama."))
		#expect(piece[1].content == "<transcript>\nhello\n</transcript>")
		#expect(!NotesPrompts.pieceMessages("hello", part: 1, of: 1)[0].content.contains("part 1 of 1"))
		#expect(NotesPrompts.mergeMessages(parts: ["a", "b"])[1].content.contains("<part number=\"2\">\nb\n</part>"))
		#expect(NotesPrompts.concatenated(parts: ["a\n", "b"]) == "# Part 1\n\na\n\n# Part 2\n\nb")
	}
}

struct OllamaChatAPITests {
	@Test
	func requestGoesToTheNativeAPI() throws {
		let body = OllamaChatAPI.Request(model: "qwen3:8b", messages: [ChatMessage(role: "user", content: "hi")])
		for base in ["http://localhost:11434", "http://localhost:11434/", "http://localhost:11434/v1", " http://localhost:11434/v1/ "] {
			let request = try OllamaChatAPI.chatRequest(baseURL: base, body: body, timeout: 600)
			#expect(request.url?.absoluteString == "http://localhost:11434/api/chat")
			#expect(request.timeoutInterval == 600)
		}
		let request = try OllamaChatAPI.chatRequest(baseURL: "http://localhost:11434", body: body, timeout: 600)
		let httpBody = try #require(request.httpBody)
		let json = try #require(try JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
		#expect(json["stream"] as? Bool == false)
		#expect(json["think"] as? Bool == false)
		#expect((json["options"] as? [String: Any])?["num_ctx"] as? Int == OllamaChatAPI.contextTokens)
	}

	@Test
	func content() throws {
		func parse(_ json: String) throws -> String { try OllamaChatAPI.content(from: Data(json.utf8)) }
		#expect(try parse(#"{"message":{"content":"  - one\n"},"done_reason":"stop"}"#) == "- one")
		#expect(try parse(#"{"message":{"content":"<think>hmm</think>\n- one"}}"#) == "- one")
		#expect(throws: ChatCompletionAPI.Failure.truncated) { try parse(#"{"message":{"content":"- on"},"done_reason":"length"}"#) }
		#expect(throws: ChatCompletionAPI.Failure.emptyResponse) { try parse(#"{"message":{"content":"<think>only thinking"}}"#) }
		#expect(throws: ChatCompletionAPI.Failure.http(status: 200, body: "model not found")) { try parse(#"{"error":"model not found"}"#) }
	}
}

struct NotesTapDetectorTests {
	let rightOption = KeyEvent(key: nil, modifiers: [.option.with(side: .right)])
	let none = KeyEvent(key: nil, modifiers: [])

	func feed(_ detector: inout NotesTapDetector, _ events: [KeyEvent]) -> [NotesTapDetector.Output] {
		events.compactMap { detector.process($0) }
	}

	@Test
	func aCleanTapFiresOnRelease() {
		var detector = NotesTapDetector(hotkey: HotKey(key: nil, modifiers: [.option.with(side: .right)]))
		#expect(detector.process(rightOption) == nil)
		#expect(detector.isHeld)
		#expect(detector.process(none) == .tapped)
		#expect(feed(&detector, [rightOption, none, rightOption, none]) == [.tapped, .tapped])
	}

	@Test
	func typingWithTheHotkeyHeldIsNotATap() {
		var detector = NotesTapDetector(hotkey: HotKey(key: nil, modifiers: [.option.with(side: .right)]))
		let typed = KeyEvent(key: .e, modifiers: [.option.with(side: .right)])
		let withControl = KeyEvent(key: nil, modifiers: [.option.with(side: .right), .control])
		#expect(feed(&detector, [rightOption, typed, rightOption, none]).isEmpty)
		#expect(feed(&detector, [rightOption, withControl, rightOption, none]).isEmpty)
		#expect(feed(&detector, [rightOption, none]) == [.tapped])
	}

	@Test
	func aLongerHoldIsReleasedNotTapped() {
		var detector = NotesTapDetector(hotkey: HotKey(key: nil, modifiers: [.option.with(side: .right)]))
		let start = Date()
		#expect(detector.process(rightOption, at: start) == nil)
		#expect(detector.process(none, at: start + NotesTapDetector.tapWindow) == .tapped)
		#expect(detector.process(rightOption, at: start + 1) == nil)
		#expect(detector.process(none, at: start + 1.31) == .released)
		// Typing with the key held is neither.
		#expect(detector.process(rightOption, at: start + 2) == nil)
		#expect(detector.process(KeyEvent(key: .e, modifiers: [.option.with(side: .right)]), at: start + 2.1) == nil)
		#expect(detector.process(none, at: start + 2.2) == nil)
	}

	@Test
	func theOtherOptionKeyIsIgnored() {
		var detector = NotesTapDetector(hotkey: HotKey(key: nil, modifiers: [.option.with(side: .right)]))
		let leftOption = KeyEvent(key: nil, modifiers: [.option.with(side: .left)])
		#expect(feed(&detector, [leftOption, none]).isEmpty)
	}

	@Test
	func keyHotkeyAndEscape() {
		var detector = NotesTapDetector(hotkey: HotKey(key: .a, modifiers: [.command]))
		let press = KeyEvent(key: .a, modifiers: [.command])
		let lift = KeyEvent(key: nil, modifiers: [.command])
		#expect(feed(&detector, [press, press, lift, none]) == [.tapped])
		#expect(feed(&detector, [press, KeyEvent(key: .escape, modifiers: []), lift]) == [.escape])
	}
}

struct NotesSpeechTests {
	static let rate = NotesChunker.sampleRate

	@Test
	func joinsSpeechInOrderWithAShortGap() {
		let samples = (0 ..< 10 * Self.rate).map { Float($0) }
		let late = 6 * Self.rate ..< 7 * Self.rate
		let early = 1 * Self.rate ..< 2 * Self.rate
		let joined = NotesSpeech.joined(samples, ranges: [late, early])
		let gap = Int(NotesSpeech.joinGapSeconds * Double(Self.rate))
		#expect(joined?.count == 2 * Self.rate + gap)
		#expect(joined?.first == Float(Self.rate))
		#expect(joined?.last == Float(7 * Self.rate - 1))
		#expect(joined?[Self.rate] == 0)
	}

	@Test
	func overlappingStretchesAreMergedAndClamped() {
		let samples = [Float](repeating: 1, count: 3 * Self.rate)
		let joined = NotesSpeech.joined(samples, ranges: [0 ..< 2 * Self.rate, Self.rate ..< 5 * Self.rate])
		#expect(joined?.count == 3 * Self.rate)
	}

	@Test
	func aQuietRoomIsBelowTheDictationFloor() {
		// −46 dBFS of steady noise, then the same with 100 ms at −30 dBFS (a short "yep").
		let quiet = [Float](repeating: 0.005, count: 5 * Self.rate)
		#expect(NotesSpeech.isBelowDictationFloor(quiet))
		var spoken = quiet
		for index in 2 * Self.rate ..< 2 * Self.rate + Self.rate / 10 { spoken[index] = 0.03 }
		#expect(!NotesSpeech.isBelowDictationFloor(spoken))
		#expect(NotesSpeech.isBelowDictationFloor([]))
	}

	@Test
	func tooLittleSpeechIsNone() {
		let samples = [Float](repeating: 1, count: 5 * Self.rate)
		#expect(NotesSpeech.joined(samples, ranges: []) == nil)
		#expect(NotesSpeech.joined(samples, ranges: [0 ..< Self.rate / 4]) == nil)
		#expect(NotesSpeech.joined(samples, ranges: [0 ..< Self.rate / 4, Self.rate ..< Self.rate + Self.rate / 4]) != nil)
	}

	@Test
	func loopsAreCaught() {
		// From a session left running in a quiet room (2026-10-10).
		#expect(NotesSpeech.looksLooped("I'm not sure if I'm going to do it. I'm not sure if I'm going to do it. I'm not sure if I'm going to do it. I'm not sure if I'm going to do it."))
		#expect(NotesSpeech.looksLooped("The only thing that I'm not sure about is that I'm not sure about the details of the book. I'm not sure about the details of the book."))
		#expect(NotesSpeech.looksLooped("I'm going to go to the next slide. I'm going to go to the next slide. I'm going to go to the next slide. I'm gonna go get some more."))
		#expect(NotesSpeech.looksLooped("The only person who is not a person who is not a person who is not a person who is not a person who"))
	}

	@Test
	func ordinarySpeechIsKept() {
		#expect(!NotesSpeech.looksLooped("But I mean, he has different numbers, he has two phones, so okay, I don't know what he uses to get the calls and whatnot. But regardless, we can just say as a thing, you sell anything that a house needs, right."))
		#expect(!NotesSpeech.looksLooped("Thank you."))
		#expect(!NotesSpeech.looksLooped("I don't know, I don't know, let me check the numbers again before we send it."))
	}

	@Test
	func silenceWatchStopsAfterTheLimitAndResetsOnSpeech() {
		var watch = NotesSilenceWatch(limit: 60)
		let results = [
			watch.record(seconds: 25, speech: false),
			watch.record(seconds: 25, speech: false),
			watch.record(seconds: 25, speech: true),
			watch.record(seconds: 30, speech: false),
			watch.record(seconds: 30, speech: false),
		]
		#expect(results == [false, false, false, false, true])
		#expect(watch.silentSeconds == 60)
	}
}

struct NotesTranscriptEditTests {
	static let transcript = NotesTranscript(lines: [
		NotesTranscriptLine(chunk: 0, text: "First part."),
		NotesTranscriptLine(chunk: 1, text: ""),
		.gap(chunk: 2),
		NotesTranscriptLine(chunk: 3, text: "Last part."),
	])

	@Test
	func heardNothingOnlyWithoutWordsOrGaps() {
		#expect(NotesTranscript(lines: []).heardNothing)
		#expect(NotesTranscript(lines: [NotesTranscriptLine(chunk: 0, text: ""), NotesTranscriptLine(chunk: 1, text: "  ")]).heardNothing)
		// A failed chunk may hold speech: its audio is kept in failed/, so the session stays.
		#expect(!NotesTranscript(lines: [NotesTranscriptLine(chunk: 0, text: ""), .gap(chunk: 1)]).heardNothing)
		#expect(!Self.transcript.heardNothing)
	}

	@Test
	func paragraphsSkipEmptyChunks() {
		#expect(Self.transcript.paragraphs == "First part.\n\n\(NotesTranscript.gapMarker)\n\nLast part.")
	}

	@Test
	func anUnchangedEditKeepsChunkNumbers() {
		let edited = Self.transcript.edited(Self.transcript.paragraphs)
		#expect(edited.lines.map(\.chunk) == [0, 2, 3])
		#expect(edited.lines[1].isGap)
		#expect(edited.text == Self.transcript.text)
	}

	@Test
	func removedAndAddedParagraphs() {
		let shorter = Self.transcript.edited("First part, fixed.\r\n\r\n\n\n")
		#expect(shorter.lines == [NotesTranscriptLine(chunk: 0, text: "First part, fixed.")])
		let longer = Self.transcript.edited("A\n\nB\n\nC\n\nD")
		#expect(longer.lines.map(\.chunk) == [0, 2, 3, 4])
		#expect(longer.gapCount == 0)
	}

	@Test
	func anEditThatDropsTheLastChunkSurvivesALoad() throws {
		let directory = FileManager.default.temporaryDirectory.appending(component: "notes-edit-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = NotesTranscriptFile(directory: directory)
		try file.commit(Self.transcript)
		try file.commit(Self.transcript)

		let edited = Self.transcript.edited("Only this.")
		try file.commitEdit(edited)
		#expect(file.load() == edited)
		#expect(FileManager.default.fileExists(atPath: file.originalURL.path))

		// A second edit keeps the first recording as the original.
		try file.commitEdit(Self.transcript.edited("Again."))
		let original = NotesTranscript.parse(try Data(contentsOf: file.originalURL))
		#expect(original == Self.transcript)
	}
}
