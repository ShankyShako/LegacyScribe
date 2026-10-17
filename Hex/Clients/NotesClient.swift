import ComposableArchitecture
import Darwin
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

/// A notes session as the Notes tab lists it.
struct NotesSessionSummary: Equatable, Identifiable, Sendable {
	var session: NotesSession
	var id: String { session.id }
	var transcribedChunks: Int
	var pendingChunks: Int
	var gaps: Int
	var words: Int
	/// Set while notes are being written.
	var progress: NotesProgress?
	/// Recorded time, from the chunk count (each chunk is 20–30 s).
	var approximateSeconds: TimeInterval
	/// Speakers heard (`SpeakerRegistry.speakerCount`); labels show only when it is over 1.
	var speakerCount: Int = 0
	/// Stretches were left out or brought back since the notes were written (`NotesSession.notesStale`).
	var notesStale = false
}

struct NotesProgress: Equatable, Sendable {
	var partsDone: Int
	var partsTotal: Int
}

struct NotesContent: Equatable, Sendable {
	var notes: String?
	var transcript: String
	/// Speakers heard. Over 1, `transcript` has a `"<label>: "` paragraph per speaker turn.
	var speakerCount: Int = 0
	/// The transcript's paragraphs with their speakers, for the Transcript tab; empty unless `speakerCount > 1`.
	var speakerParagraphs: [NotesSpeakerParagraph] = []
	/// The whole transcript, left-out stretches included, one paragraph per line or turn: what Edit shows.
	/// `transcript` leaves the trims out, so Copy and Export omit them.
	var fullTranscript: String = ""
	/// Every sentence in order with its place on the timeline, for the Transcript tab and the Trim strip.
	var sentences: [NotesSentenceItem] = []
	/// The left-out stretches, in order.
	var trims: [NotesTrimRow] = []
	/// The notes were written before the latest trim change.
	var notesStale = false
	/// Recorded time; nil while the session is still recording.
	var sessionSeconds: Double?
}

/// One sentence of the transcript as the Transcript tab and the Trim strip use it.
struct NotesSentenceItem: Equatable, Sendable {
	var point: NotesTrimPoint
	var text: String
	/// First sentence of its speaker turn or chunk.
	var startsParagraph: Bool
	/// The paragraph's speaker and chip fields (`text` is empty).
	var paragraph: NotesSpeakerParagraph
	/// Estimated seconds from the session's start.
	var start: Double
	var end: Double
	/// Index in `NotesContent.trims` of the stretch leaving this sentence out.
	var trimIndex: Int?
}

/// A left-out stretch with its estimated place and first words.
struct NotesTrimRow: Equatable, Sendable {
	var index: Int
	var start: Double
	var end: Double
	var gist: String
}

/// One paragraph of a labelled transcript as the Transcript tab draws it.
struct NotesSpeakerParagraph: Equatable, Sendable {
	/// Nil for an unlabelled chunk or a gap.
	var speaker: Int?
	var label: String?
	/// The user's own voiceprint speaker ("You").
	var isUser: Bool
	/// Shown as "You" because the user named the speaker "Me", not recognised by voice: it can be renamed.
	var markedAsUser: Bool = false
	var text: String
	var overlapping: Bool
	/// The speaker's speech in the whole session, for the naming popover.
	var seconds: Double = 0
	/// Matched to a remembered person's voiceprint when the session started ("Recognised by voice").
	var recognised: Bool = false
	/// Named in this session with the voice saved for future sessions.
	var voiceSaved: Bool = false
	/// A remembered person's stored voiceprint: their colour is fixed by it in every session and in Settings.
	var voiceprintID: String?
}

enum NotesEvent: Equatable, Sendable {
	/// A session's stage, progress or files changed.
	case changed(String)
	/// The microphone or the disk let the running session down.
	case captureFailed(String)
	/// Nobody has spoken in the recording session for `NotesSilenceWatch.limit`; the app stops it.
	case silenceLimitReached
	/// A finished session in which nothing was heard was deleted instead of listed.
	case discardedSilent(String)
}

enum NotesError: Error, LocalizedError, Equatable {
	case cohereMissing
	case alreadyRecording
	case recordingNow
	case writingNotes
	case transcriptIncomplete

	var errorDescription: String? {
		switch self {
		case .cohereMissing: "Notes needs Cohere Transcribe: download it in Settings > Models"
		case .alreadyRecording: "A notes session is already recording"
		case .recordingNow: "Stop the session first"
		case .writingNotes: "Wait until the notes are written"
		case .transcriptIncomplete: "Wait until the transcript is complete"
		}
	}
}

/// Notes sessions: hands-free capture, live transcription by Cohere, notes by local Ollama afterwards.
/// See "Notes mode" in `docs/plan.md`.
@DependencyClient
struct NotesClient {
	/// Starts capture for a new session and returns its ID.
	var start: @Sendable () async throws -> String
	/// Stops capture; transcription and notes carry on in the background.
	var stop: @Sendable () async -> Void
	/// Stops capture and deletes the session: it was started by mistake.
	var discard: @Sendable () async -> Void
	var events: @Sendable () -> AsyncStream<NotesEvent> = { AsyncStream { $0.finish() } }
	var meters: @Sendable () -> AsyncStream<Meter> = { AsyncStream { $0.finish() } }
	/// Picks up sessions a quit or crash left unfinished.
	var resumeUnfinished: @Sendable () async -> Void
	/// Writes the notes again: after a failure, or for finished notes (with the current model).
	var retryNotes: @Sendable (_ id: String) async -> Void
	/// Replaces a finished session's transcript with the user's edit (one paragraph per chunk) and writes
	/// the notes again from it.
	var saveTranscript: @Sendable (_ id: String, _ text: String) async throws -> Void
	/// Leaves the sentences from `from` to `to` out of the notes (`NotesTrims`). The transcript is untouched and
	/// the notes are not rewritten: the user does that with "Write notes again".
	var leaveOut: @Sendable (_ id: String, _ from: NotesTrimPoint, _ to: NotesTrimPoint) async throws -> Void
	/// Puts the trim at `index` back into the notes.
	var bringBack: @Sendable (_ id: String, _ index: Int) async throws -> Void
	var list: @Sendable () async -> [NotesSessionSummary] = { [] }
	var content: @Sendable (_ id: String) async -> NotesContent = { _ in NotesContent(notes: nil, transcript: "") }
	var delete: @Sendable (_ id: String) async throws -> Void
	/// Learns the user's voiceprint from these History entries' recordings and saves it, replacing any earlier
	/// one. `progress` gets the fraction of recordings done.
	var enrolVoiceprint: @Sendable (_ history: [Transcript], _ progress: @escaping @Sendable (Double) -> Void) async throws -> Voiceprint
	/// The user's voiceprint, if one was learned.
	var voiceprint: @Sendable () async -> Voiceprint? = { nil }
	/// Forgets the user's voiceprint. Notes and transcripts are untouched.
	var deleteVoiceprint: @Sendable () async throws -> Void
	/// Names a speaker of a session (`SpeakerNaming`): stored in its `speakers.json`; with `remember`, the
	/// voice is saved so later sessions recognise it.
	var nameSpeaker: @Sendable (_ id: String, _ speaker: Int, _ name: String, _ remember: Bool) async throws -> Void
	/// Other people's voiceprints, named in notes transcripts.
	var rememberedVoices: @Sendable () async -> [Voiceprint] = { [] }
	/// Forgets one of them. Transcripts keep the name.
	var forgetRememberedVoice: @Sendable (_ voiceprintID: String) async throws -> Void
}

extension NotesClient: DependencyKey {
	static var liveValue: Self {
		let engine = NotesEngine()
		return Self(
			start: { try await engine.start() },
			stop: { await engine.stop() },
			discard: { await engine.discard() },
			events: { engine.events.subscribe() },
			meters: { engine.meters.subscribe() },
			resumeUnfinished: { await engine.resumeUnfinished() },
			retryNotes: { await engine.retryNotes($0) },
			saveTranscript: { try await engine.saveTranscript($0, text: $1) },
			leaveOut: { try await engine.leaveOut($0, from: $1, to: $2) },
			bringBack: { try await engine.bringBack($0, index: $1) },
			list: { await engine.list() },
			content: { await engine.content($0) },
			delete: { try await engine.delete($0) },
			enrolVoiceprint: { try await engine.enrolVoiceprint(history: $0, progress: $1) },
			voiceprint: { await engine.voiceprint() },
			deleteVoiceprint: { try await engine.deleteVoiceprint() },
			nameSpeaker: { try await engine.nameSpeaker($0, speaker: $1, name: $2, remember: $3) },
			rememberedVoices: { await engine.rememberedVoices() },
			forgetRememberedVoice: { try await engine.forgetRememberedVoice($0) }
		)
	}
}

extension DependencyValues {
	var notes: NotesClient {
		get { self[NotesClient.self] }
		set { self[NotesClient.self] = newValue }
	}
}

extension URL {
	/// `<data root>/Notes/`: one folder per session, named by its start time.
	static var notesFolderURL: URL {
		(try? URL.hexApplicationSupport.appending(component: "Notes", directoryHint: .isDirectory))
			?? URL.documentsDirectory.appending(component: "Notes", directoryHint: .isDirectory)
	}
}

/// Fans values out to every subscriber; usable from any thread.
final class NotesBroadcast<Element: Sendable>: @unchecked Sendable {
	private let lock = NSLock()
	private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

	func subscribe() -> AsyncStream<Element> {
		let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(16))
		let id = UUID()
		lock.withLock { continuations[id] = continuation }
		continuation.onTermination = { [weak self] _ in
			self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
		}
		return stream
	}

	func yield(_ value: Element) {
		for continuation in lock.withLock({ Array(continuations.values) }) {
			continuation.yield(value)
		}
	}
}

actor NotesEngine {
	/// Its own instance, loaded for a whole session; dictation's Cohere is loaded per dictation.
	private let cohere = CohereClient()
	private let cohereModel = CohereModel.fourBit.identifier
	private let voice = NotesVoiceDetector()
	/// Splits chunks by speaker when `notesSpeakerLabels` is on.
	private let speakers = NotesSpeakerSplitter()
	/// Each unfinished session's speakers, mirrored in its `speakers.json`.
	private var registries: [String: SpeakerRegistry] = [:]
	/// Sessions whose speaker split already failed once (logged once, then unlabelled quietly).
	private var speakerFailureLogged: Set<String> = []
	/// Silence in the recording session, and whether the app was already told to stop it.
	private var silence = NotesSilenceWatch()
	private var silenceReported = false
	private let logger = HexLog.notes
	@Shared(.hexSettings) private var hexSettings: HexSettings

	nonisolated let events = NotesBroadcast<NotesEvent>()
	nonisolated let meters = NotesBroadcast<Meter>()

	private var capture: NotesCaptureController?
	private var capturingID: String?
	/// Unfinished sessions the worker is driving, by ID.
	private var sessions: [String: NotesSession] = [:]
	private var transcripts: [String: NotesTranscript] = [:]
	/// Sessions waiting for Retry: their notes failed, or their transcript couldn't be saved.
	private var parked: Set<String> = []
	private var progress: [String: NotesProgress] = [:]
	private var worker: Task<Void, Never>?
	private nonisolated let wakeStream: AsyncStream<Void>
	private nonisolated let wakeContinuation: AsyncStream<Void>.Continuation

	/// Above this the process footprint is reset by reloading Cohere (MLX caches grow over long runs).
	private static let footprintLimit: UInt64 = 3 << 30
	/// A long piece can take a local model minutes; nothing waits on it.
	private static let ollamaTimeout: TimeInterval = 600

	private let urlSession: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.waitsForConnectivity = false
		return URLSession(configuration: configuration)
	}()

	init() {
		(wakeStream, wakeContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
	}

	private func folder(_ id: String) -> NotesSessionFolder {
		NotesSessionFolder(URL.notesFolderURL.appending(component: id, directoryHint: .isDirectory))
	}

	private var voiceprints: VoiceprintStore {
		VoiceprintStore(directory: .voiceprintsFolderURL)
	}

	/// A new session's speakers: the stored voiceprints, the user's first ("You"). A person saved as "Me"
	/// is the user too, so once the user's own voice is learned it isn't seeded beside it.
	private func seededRegistry() -> SpeakerRegistry {
		let all = voiceprints.all()
		let hasUser = all.contains(where: \.isUser)
		return SpeakerRegistry(voiceprints: all.filter { $0.isUser || !(hasUser && SpeakerRegistry.isSelfName($0.name)) })
	}

	/// The session's speakers: in memory while it is unfinished, else from `speakers.json`.
	private func registry(_ id: String) -> SpeakerRegistry? {
		registries[id] ?? folder(id).loadSpeakers()
	}

	/// The speakers as the transcript, notes and edits show them: strays, repeated names and "Me" merged.
	private func shownRegistry(_ id: String) -> SpeakerRegistry? {
		registry(id)?.consolidated()
	}

	nonisolated func wake() {
		wakeContinuation.yield()
	}

	// MARK: - Capture

	/// `microphone: false` (Debug only) skips the audio engine; the harness feeds samples with `ingest`.
	func start(microphone: Bool = true) async throws -> String {
		guard capture == nil else { throw NotesError.alreadyRecording }
		guard await cohere.isModelAvailable(cohereModel) else { throw NotesError.cohereMissing }

		var startedAt = Date()
		var id = NotesSession.id(for: startedAt)
		while FileManager.default.fileExists(atPath: folder(id).url.path) {
			startedAt += 1
			id = NotesSession.id(for: startedAt)
		}
		let folder = folder(id)
		try folder.createDirectories()
		let session = NotesSession(id: id, startedAt: startedAt)
		try folder.saveManifest(session)

		let events = events
		let meters = meters
		let capture = NotesCaptureController(
			folder: folder,
			deviceUID: hexSettings.selectedMicrophoneID,
			voiceIsolation: hexSettings.voiceIsolationInNotes,
			onChunk: { [weak self] _ in self?.wake() },
			onMeter: { meters.yield($0) },
			onFailure: { events.yield(.captureFailed($0)) }
		)
		do {
			if microphone { try capture.start() }
		} catch {
			try? FileManager.default.removeItem(at: folder.url)
			throw error
		}
		self.capture = capture
		capturingID = id
		sessions[id] = session
		transcripts[id] = NotesTranscript()
		registries[id] = seededRegistry()
		silence = NotesSilenceWatch()
		silenceReported = false
		let labelSpeakers = hexSettings.notesSpeakerLabels
		Task { [voice, speakers, logger] in
			do {
				try await voice.prepare()
			} catch {
				logger.error("Notes speech detector unavailable, chunks are transcribed whole: \(error.localizedDescription, privacy: .public)")
			}
			guard labelSpeakers else { return }
			do {
				try await speakers.prepare()
			} catch {
				logger.error("Notes speaker model unavailable, the transcript stays unlabelled: \(error.localizedDescription, privacy: .public)")
			}
		}
		startWorker()
		logger.notice("Notes session \(id, privacy: .public) started")
		events.yield(.changed(id))
		return id
	}

	#if DEBUG
	func ingest(_ samples: [Float]) {
		capture?.ingest(samples)
	}

	/// Chunks listed in `LEGACYSCRIBE_NOTES_FAIL` ("5x1,8x2": chunk 5 fails once, chunk 8 twice) throw
	/// instead of transcribing, to force Cohere resets in the crash test.
	private static let injectedFailures: [Int: Int] = {
		let spec = ProcessInfo.processInfo.environment["LEGACYSCRIBE_NOTES_FAIL"] ?? ""
		return Dictionary(spec.split(separator: ",").compactMap { item -> (Int, Int)? in
			let parts = item.split(separator: "x")
			guard parts.count == 2, let chunk = Int(parts[0]), let times = Int(parts[1]) else { return nil }
			return (chunk, times)
		}, uniquingKeysWith: { $1 })
	}()

	struct InjectedFailure: Error {}
	#endif

	func stop() {
		guard let capture, let id = capturingID else { return }
		let chunks = capture.stop()
		self.capture = nil
		capturingID = nil
		update(id) {
			$0.stage = .transcribing
			$0.endedAt = Date()
		}
		logger.notice("Notes session \(id, privacy: .public) stopped after \(chunks) chunks")
		wake()
	}

	/// Stops capture and deletes the session folder. Only for the first seconds of a session, before the
	/// first chunk (~25 s) is cut, so no transcription of it can be running.
	func discard() {
		guard let capture, let id = capturingID else { return }
		_ = capture.stop()
		self.capture = nil
		capturingID = nil
		sessions[id] = nil
		transcripts[id] = nil
		registries[id] = nil
		progress[id] = nil
		FileManager.default.removeItemIfExists(at: folder(id).url)
		logger.notice("Notes session \(id, privacy: .public) discarded")
		events.yield(.changed(id))
	}

	// MARK: - Worker

	private enum Job {
		case transcribe(String, chunk: Int)
		case finishTranscribing(String)
		case writeNotes(String)
	}

	private func startWorker() {
		guard worker == nil else { return }
		worker = Task { [weak self] in
			guard let self else { return }
			for await _ in wakeStream {
				while let job = await nextJob() {
					await perform(job)
				}
			}
		}
		wake()
	}

	/// Transcription first (it keeps up with a live session), then stage changes, then notes. Notes wait
	/// until no session is recording, so Cohere and the local model are never loaded together.
	private func nextJob() -> Job? {
		let ids = sessions.keys.sorted().filter { !parked.contains($0) }
		for id in ids {
			guard let stage = sessions[id]?.stage, stage == .recording || stage == .transcribing else { continue }
			if let chunk = folder(id).pendingChunks().first {
				return .transcribe(id, chunk: chunk)
			}
		}
		for id in ids where sessions[id]?.stage == .transcribing {
			return .finishTranscribing(id)
		}
		guard capturingID == nil else { return nil }
		for id in ids where sessions[id]?.stage == .noting {
			return .writeNotes(id)
		}
		return nil
	}

	private func perform(_ job: Job) async {
		switch job {
		case let .transcribe(id, chunk):
			await transcribe(id, chunk: chunk)
		case let .finishTranscribing(id):
			if (transcripts[id] ?? folder(id).transcript.load()).heardNothing {
				// Nothing to write notes from: the session isn't listed.
				do {
					try delete(id)
					events.yield(.discardedSilent(id))
				} catch {
					logger.error("Silent notes session \(id, privacy: .public) not deleted: \(error.localizedDescription, privacy: .public)")
					update(id) { $0.stage = .noting }
				}
				return
			}
			update(id) { $0.stage = .noting }
		case let .writeNotes(id):
			await writeNotes(id)
		}
	}

	/// Transcribes one pending chunk, commits it to the transcript, then deletes its audio.
	private func transcribe(_ id: String, chunk: Int) async {
		let folder = folder(id)
		let url = folder.pendingChunkURL(chunk)
		var transcript = transcripts[id] ?? folder.transcript.load()
		if transcript.contains(chunk: chunk) {
			FileManager.default.removeItemIfExists(at: url)
			return
		}

		let samples = (try? Data(contentsOf: url)).flatMap(PCM16WAV.samples(from:))
		var line: NotesTranscriptLine
		var spoke: Bool
		var registry: SpeakerRegistry?
		switch await audioToTranscribe(samples, url: url, chunk: chunk) {
		case .silent:
			line = NotesTranscriptLine(chunk: chunk, text: "")
			spoke = false
		case .whole:
			(line, spoke) = await transcribeLine(url, chunk: chunk)
		case let .speech(chunkSamples, ranges, joined):
			if hexSettings.notesSpeakerLabels,
			   let turns = await speakerTurns(id, samples: chunkSamples, speech: ranges, chunk: chunk),
			   let result = await transcribeTurns(turns, samples: chunkSamples, id: id, chunk: chunk) {
				switch result {
				case .gap:
					line = .gap(chunk: chunk)
					spoke = true
				case let .line(turnsLine, updated):
					line = turnsLine
					spoke = !(turnsLine.turns ?? []).isEmpty
					registry = updated
				}
			} else {
				let speechURL = FileManager.default.temporaryDirectory.appending(component: "notes-speech-\(UUID().uuidString).wav")
				defer { FileManager.default.removeItemIfExists(at: speechURL) }
				do {
					try PCM16WAV.data(samples: joined).write(to: speechURL)
					(line, spoke) = await transcribeLine(speechURL, chunk: chunk)
				} catch {
					logger.error("Notes chunk \(chunk) speech not written, transcribing all of it: \(error.localizedDescription, privacy: .public)")
					(line, spoke) = await transcribeLine(url, chunk: chunk)
				}
			}
		}
		// The session may have been deleted while Cohere ran.
		guard sessions[id] != nil else { return }
		// Speakers are saved before the transcript: a registry ahead of the transcript is harmless, one
		// behind it would renumber speakers after a crash.
		// A speaker named while this chunk was transcribed keeps the name.
		if var registry {
			if let current = registries[id] { registry.adoptNames(from: current) }
			if registry != registries[id] {
				do {
					try folder.saveSpeakers(registry)
				} catch {
					logger.error("Notes speakers of \(id, privacy: .public) not saved: \(error.localizedDescription, privacy: .public)")
					park(id, error: "The transcript couldn't be saved: \(error.localizedDescription)")
					return
				}
				registries[id] = registry
			}
		}
		if id == capturingID, !silenceReported,
		   silence.record(seconds: Double(samples?.count ?? 0) / Double(NotesChunker.sampleRate), speech: spoke) {
			silenceReported = true
			logger.notice("Notes session \(id, privacy: .public): no speech for \(Int(self.silence.silentSeconds)) s, asking to stop")
			events.yield(.silenceLimitReached)
		}

		transcript = transcripts[id] ?? transcript
		// The chunk's length, for the Trim timeline; absent when its file couldn't be read.
		line.seconds = samples.map { Double($0.count) / Double(NotesChunker.sampleRate) }
		transcript.add(line)
		do {
			try folder.transcript.commit(transcript)
		} catch {
			logger.error("Notes transcript of \(id, privacy: .public) not saved: \(error.localizedDescription, privacy: .public)")
			park(id, error: "The transcript couldn't be saved: \(error.localizedDescription)")
			return
		}
		transcripts[id] = transcript
		if line.isGap {
			try? FileManager.default.createDirectory(at: folder.failedURL, withIntermediateDirectories: true)
			try? FileManager.default.moveItem(at: url, to: folder.failedChunkURL(chunk))
		} else {
			FileManager.default.removeItemIfExists(at: url)
		}
		if Self.footprint() > Self.footprintLimit {
			logger.notice("Notes footprint over the limit; reloading Cohere")
			await cohere.unload()
		}
		events.yield(.changed(id))
	}

	private enum ChunkAudio {
		/// Nothing worth transcribing.
		case silent
		/// Transcribe the chunk file as it is (the detector or the file couldn't be read).
		case whole
		/// The chunk's samples, the speech in them, and that speech joined.
		case speech([Float], ranges: [Range<Int>], joined: [Float])
	}

	/// The chunk's speech only, so Cohere never sees long silence. The whole chunk when the detector or the
	/// file can't be read, so a detector problem never costs speech.
	private func audioToTranscribe(_ samples: [Float]?, url: URL, chunk: Int) async -> ChunkAudio {
		guard let samples else { return .whole }
		if NotesChunker.isSilent(samples) { return .silent }
		do {
			let ranges = try await voice.speechRanges(in: samples)
			guard let speech = NotesSpeech.joined(samples, ranges: ranges) else {
				logger.notice("Notes chunk \(chunk): no speech")
				return .silent
			}
			return .speech(samples, ranges: ranges, joined: speech)
		} catch {
			logger.error("Notes chunk \(chunk) speech detection failed, transcribing all of it: \(error.localizedDescription, privacy: .public)")
			return .whole
		}
	}

	/// The chunk as one unlabelled line, and whether anything was said. Nil text after two tries → a gap.
	private func transcribeLine(_ source: URL, chunk: Int) async -> (NotesTranscriptLine, Bool) {
		guard let text = await transcribeWithRetry(source, chunk: chunk) else { return (.gap(chunk: chunk), true) }
		if NotesSpeech.looksLooped(text) {
			logger.notice("Notes chunk \(chunk) dropped: the same words over and over (\(NotesTranscript.wordCount(text)) words)")
			return (NotesTranscriptLine(chunk: chunk, text: ""), false)
		}
		return (NotesTranscriptLine(chunk: chunk, text: text), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
	}

	/// The chunk's speaker turns; nil (transcribe it unlabelled) when the diarizer fails or finds none.
	private func speakerTurns(_ id: String, samples: [Float], speech: [Range<Int>], chunk: Int) async -> [NotesTurn]? {
		do {
			let turns = NotesTurns.turns(from: try await speakers.segments(in: samples), speech: speech)
			if turns.isEmpty { logger.notice("Notes chunk \(chunk): no speaker turns, transcribed unlabelled") }
			return turns.isEmpty ? nil : turns
		} catch {
			if speakerFailureLogged.insert(id).inserted {
				logger.error("Notes speaker split failed for \(id, privacy: .public), chunks stay unlabelled: \(error.localizedDescription, privacy: .public)")
			}
			return nil
		}
	}

	private enum TurnsResult {
		/// A turn failed twice: the whole chunk becomes a gap, as an unlabelled chunk would.
		case gap
		/// The line and the session's speakers after it.
		case line(NotesTranscriptLine, SpeakerRegistry)
	}

	/// Transcribes each turn on its own and gives it a session speaker. Turns with no text, or looping text,
	/// are dropped (and assign no speaker); neighbouring turns of one speaker are joined. Nil when a turn's
	/// audio can't be written, so the chunk is transcribed unlabelled instead.
	private func transcribeTurns(_ turns: [NotesTurn], samples: [Float], id: String, chunk: Int) async -> TurnsResult? {
		var registry = registries[id] ?? seededRegistry()
		var kept: [NotesTranscriptTurn] = []
		for turn in turns {
			guard let audio = NotesSpeech.joined(samples, ranges: turn.speech) else { continue }
			let turnURL = FileManager.default.temporaryDirectory.appending(component: "notes-turn-\(UUID().uuidString).wav")
			defer { FileManager.default.removeItemIfExists(at: turnURL) }
			do {
				try PCM16WAV.data(samples: audio).write(to: turnURL)
			} catch {
				logger.error("Notes chunk \(chunk) turn not written, transcribing unlabelled: \(error.localizedDescription, privacy: .public)")
				return nil
			}
			guard let text = await transcribeWithRetry(turnURL, chunk: chunk) else { return .gap }
			let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { continue }
			if NotesSpeech.looksLooped(trimmed) {
				logger.notice("Notes chunk \(chunk) turn dropped: the same words over and over (\(NotesTranscript.wordCount(trimmed)) words)")
				continue
			}
			// A short turn that matches no one goes to the speaker before it: in this chunk, else the last one.
			let neighbour = kept.last?.speaker ?? transcripts[id]?.lines.last(where: { $0.turns != nil })?.turns?.last?.speaker
			let speaker = registry.assign(
				turn.embedding, seconds: Double(turn.speechSamples) / Double(NotesChunker.sampleRate), neighbour: neighbour
			)
			var overlapping = turn.overlapping
			if !overlapping { overlapping = await userTalksOver(audio, speaker: speaker, registry: registry, chunk: chunk) }
			if let last = kept.last, last.speaker == speaker {
				kept[kept.count - 1].text += " " + trimmed
				if overlapping { kept[kept.count - 1].overlapping = true }
			} else {
				kept.append(NotesTranscriptTurn(speaker: speaker, text: trimmed, overlapping: overlapping))
			}
		}
		logger.notice("Notes chunk \(chunk): \(turns.count) turns, speakers \(kept.map { "\($0.speaker)\($0.isOverlapping ? "+" : "")" }.joined(separator: ","), privacy: .public)")
		return .line(NotesTranscriptLine(chunk: chunk, turns: kept), registry)
	}

	/// Whether the user's voiceprint is heard in a turn given to someone else (`SpeakerOverlap`): the user
	/// talking over them. False without a voiceprint, for the user's own turns, and when scoring fails.
	private func userTalksOver(_ audio: [Float], speaker: Int, registry: SpeakerRegistry, chunk: Int) async -> Bool {
		guard let user = registry.speakers.first(where: { $0.voiceprintID == Voiceprint.userID }), user.id != speaker else {
			return false
		}
		let windows = SpeakerOverlap.windows(sampleCount: audio.count)
		guard !windows.isEmpty else { return false }
		do {
			return SpeakerOverlap.userHeard(try await speakers.scores(audio, windows: windows, against: user.embedding))
		} catch {
			logger.error("Notes chunk \(chunk) overlap check failed: \(error.localizedDescription, privacy: .public)")
			return false
		}
	}

	/// One reload and a second try; nil if both fail.
	private func transcribeWithRetry(_ url: URL, chunk: Int) async -> String? {
		for attempt in 1 ... 2 {
			do {
				#if DEBUG
				if let times = Self.injectedFailures[chunk], attempt <= times { throw InjectedFailure() }
				#endif
				return try await cohere.transcribe(url, modelName: cohereModel)
			} catch {
				logger.error("Notes chunk \(chunk) attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
				await cohere.unload()
			}
		}
		return nil
	}

	private func writeNotes(_ id: String) async {
		await cohere.unload()
		let folder = folder(id)
		let transcript = transcripts[id] ?? folder.transcript.load()
		// Sessions transcribed before the loop check (or edited back in) may still hold looped chunks.
		// What the user left out (`trims.json`) is not written about; the version is recorded with the notes.
		let trims = folder.loadTrims()
		let pieces = NotesPrompts.pieces(trims.applied(to: transcript).filter { !NotesSpeech.looksLooped($0.text ?? "") })
		// Labels only when more than one speaker was heard, so a solo session's notes are written as before.
		let labels = shownRegistry(id)?.transcriptLabels
		let model = (hexSettings.notesWriter == .onDevice ? hexSettings.notesLocalModel : hexSettings.notesModel)
			.trimmingCharacters(in: .whitespaces)
		let saved = folder.savedParts()
		var parts: [String] = []
		progress[id] = NotesProgress(partsDone: saved.filter { $0 <= pieces.count }.count, partsTotal: pieces.count)
		events.yield(.changed(id))

		do {
			for (offset, piece) in pieces.enumerated() {
				let number = offset + 1
				if saved.contains(number), let text = try? String(contentsOf: folder.partURL(number), encoding: .utf8) {
					parts.append(text)
					continue
				}
				let messages = NotesPrompts.pieceMessages(
					NotesTranscript.text(of: piece, labels: labels), part: number, of: pieces.count,
					vocabulary: hexSettings.vocabulary, speakerLabels: labels != nil
				)
				let text = try await chat(messages, model: model, maxTokens: Self.pieceMaxTokens)
				guard sessions[id] != nil else { return }
				try FileManager.default.createDirectory(at: folder.partsURL, withIntermediateDirectories: true)
				try text.write(to: folder.partURL(number), atomically: true, encoding: .utf8)
				parts.append(text)
				progress[id] = NotesProgress(partsDone: number, partsTotal: pieces.count)
				events.yield(.changed(id))
			}

			let notes: String
			switch parts.count {
			case 0: notes = "_No speech was recognized in this session._"
			case 1: notes = parts[0]
			default:
				do {
					notes = try await chat(NotesPrompts.mergeMessages(parts: parts), model: model, maxTokens: Self.mergeMaxTokens)
				} catch {
					logger.error("Notes merge for \(id, privacy: .public) failed, joining the parts: \(error.localizedDescription, privacy: .public)")
					notes = NotesPrompts.concatenated(parts: parts)
				}
			}
			guard sessions[id] != nil else { return }
			try notes.write(to: folder.notesURL, atomically: true, encoding: .utf8)
			export(id, notes: notes)
		} catch {
			logger.error("Notes for \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
			progress[id] = nil
			park(id, error: error.localizedDescription)
			return
		}

		update(id) {
			$0.stage = .done
			$0.notesModel = model
			$0.notesError = nil
			$0.notesTrimsVersion = trims.version
		}
		sessions[id] = nil
		transcripts[id] = nil
		registries[id] = nil
		progress[id] = nil
		logger.notice("Notes for \(id, privacy: .public) written")
		events.yield(.changed(id))
	}

	/// A piece is ~1,500 words, so its notes fit well inside this; a model that loops hits it in about a
	/// minute instead of three. The merge of many parts can legitimately run longer.
	private static let pieceMaxTokens = 4_096
	private static let mergeMaxTokens = 8_192

	private func chat(_ messages: [ChatMessage], model: String, maxTokens: Int) async throws -> String {
		if hexSettings.notesWriter == .onDevice {
			// In-process like dictation's rewrite. Sampling varies between runs, and now and then the small
			// model repeats itself until the token cap (seen in the crash test); one more try with repeats
			// penalised usually finishes.
			do {
				return try await localChat(messages, model: model, maxTokens: maxTokens, repetitionPenalty: nil)
			} catch ChatCompletionAPI.Failure.truncated {
				logger.notice("Notes answer hit \(maxTokens) tokens; trying once more with repeats penalised")
				return try await localChat(messages, model: model, maxTokens: maxTokens, repetitionPenalty: 1.1)
			}
		}
		let request = try OllamaChatAPI.chatRequest(
			baseURL: hexSettings.notesOllamaURL,
			body: OllamaChatAPI.Request(model: model, messages: messages),
			timeout: Self.ollamaTimeout
		)
		let session = urlSession
		let data = try await withDeadline(seconds: Self.ollamaTimeout) {
			let (data, response) = try await session.data(for: request)
			try ChatCompletionAPI.checkStatus((response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
			return data
		}
		return try OllamaChatAPI.content(from: data)
	}

	/// A copy of the notes in the export folder, if one is set. Failing here never fails the notes.
	private func localChat(_ messages: [ChatMessage], model: String, maxTokens: Int, repetitionPenalty: Float?) async throws -> String {
		try await withDeadline(seconds: Self.ollamaTimeout) {
			try await LocalLLM.shared.complete(repository: model, messages: messages, maxTokens: maxTokens, repetitionPenalty: repetitionPenalty)
		}
	}

	private func export(_ id: String, notes: String) {
		guard let path = hexSettings.notesExportFolder, !path.isEmpty else { return }
		let destination = URL(filePath: path, directoryHint: .isDirectory).appending(component: "Notes \(id).md")
		do {
			try notes.write(to: destination, atomically: true, encoding: .utf8)
		} catch {
			logger.error("Notes export to \(path, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
		}
	}

	// MARK: - Sessions

	private func update(_ id: String, _ change: (inout NotesSession) -> Void) {
		guard var session = sessions[id] else { return }
		change(&session)
		sessions[id] = session
		do {
			try folder(id).saveManifest(session)
		} catch {
			logger.error("Notes manifest of \(id, privacy: .public) not saved: \(error.localizedDescription, privacy: .public)")
		}
		events.yield(.changed(id))
	}

	private func park(_ id: String, error: String) {
		parked.insert(id)
		update(id) { $0.notesError = error }
	}

	func resumeUnfinished() {
		for id in Self.sessionIDs() where id != capturingID && sessions[id] == nil {
			let folder = folder(id)
			guard var session = folder.loadManifest(), session.stage != .done else { continue }
			let transcript = folder.transcript.load()
			for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.pendingURL.path)) ?? [] where name.hasSuffix(".partial") {
				FileManager.default.removeItemIfExists(at: folder.pendingURL.appending(component: name))
			}
			let plan = NotesRecovery.plan(stage: session.stage, pending: folder.pendingChunks(), transcript: transcript)
			for chunk in plan.alreadyTranscribed {
				FileManager.default.removeItemIfExists(at: folder.pendingChunkURL(chunk))
			}
			if session.stage == .recording {
				session.endedAt = Self.lastWrite(in: folder) ?? session.startedAt
			}
			session.stage = plan.stage
			session.notesError = nil
			sessions[id] = session
			transcripts[id] = transcript
			// Missing (recorded before labels, or no turn yet): later chunks may add numbers, which is fine.
			registries[id] = folder.loadSpeakers() ?? seededRegistry()
			update(id) { _ in }
			logger.notice("Notes session \(id, privacy: .public) resumed at \(plan.stage.rawValue, privacy: .public), \(plan.queue.count) chunks pending")
		}
		if !sessions.isEmpty {
			startWorker()
		}
	}

	func retryNotes(_ id: String) {
		guard id != capturingID else { return }
		parked.remove(id)
		if sessions[id] == nil {
			let folder = folder(id)
			guard var session = folder.loadManifest() else { return }
			if session.stage == .done {
				// Written again from scratch, with the current model and prompt.
				for part in folder.savedParts() {
					FileManager.default.removeItemIfExists(at: folder.partURL(part))
				}
				session.stage = .noting
			}
			sessions[id] = session
		}
		update(id) { $0.notesError = nil }
		startWorker()
		wake()
	}

	func list() -> [NotesSessionSummary] {
		Self.sessionIDs().reversed().compactMap { id in
			let folder = folder(id)
			guard let session = sessions[id] ?? folder.loadManifest() else { return nil }
			let transcript = transcripts[id] ?? folder.transcript.load()
			let pending = folder.pendingChunks().filter { !transcript.contains(chunk: $0) }.count
			let chunks = transcript.lines.count + pending
			return NotesSessionSummary(
				session: session,
				transcribedChunks: transcript.lines.count,
				pendingChunks: pending,
				gaps: transcript.gapCount,
				words: NotesTranscript.wordCount(transcript.text),
				progress: progress[id],
				approximateSeconds: session.endedAt.map { $0.timeIntervalSince(session.startedAt) }
					?? Double(chunks) * Double(NotesChunker.maxSeconds + NotesChunker.minSeconds) / 2,
				speakerCount: shownRegistry(id)?.speakerCount ?? 0,
				notesStale: session.notesStale(trimsVersion: folder.loadTrims().version)
			)
		}
	}

	func content(_ id: String) -> NotesContent {
		let folder = folder(id)
		let registry = shownRegistry(id)
		let transcript = transcripts[id] ?? folder.transcript.load()
		let labels = registry?.transcriptLabels
		let trims = folder.loadTrims()
		let session = sessions[id] ?? folder.loadManifest()
		let sessionSeconds = session?.endedAt.map { $0.timeIntervalSince(session!.startedAt) }
		let timeline = NotesTimeline.build(transcript, trims: trims, sessionSeconds: sessionSeconds)
		let sentences = NotesTrims.sentences(of: transcript)
		return NotesContent(
			notes: try? String(contentsOf: folder.notesURL, encoding: .utf8),
			transcript: NotesTranscript(lines: trims.applied(to: transcript)).paragraphs(labels: labels),
			speakerCount: registry?.speakerCount ?? 0,
			speakerParagraphs: labels == nil ? [] : transcript.speakerParagraphs.map {
				Self.paragraph(speaker: $0.speaker, text: $0.text, overlapping: $0.overlapping, registry: registry)
			},
			fullTranscript: transcript.paragraphs(labels: labels),
			sentences: Self.sentenceItems(transcript, sentences: sentences, timeline: timeline, labelled: labels != nil, registry: registry),
			trims: trims.trims.enumerated().map { index, trim in
				let span = timeline.filter { $0.trimIndex == index }
				return NotesTrimRow(
					index: index, start: span.first?.start ?? 0, end: span.last?.end ?? 0,
					gist: NotesTrims.gist(of: trim, in: sentences)
				)
			},
			notesStale: session?.notesStale(trimsVersion: trims.version) ?? false,
			sessionSeconds: sessionSeconds
		)
	}

	/// A paragraph's chip fields; the unlabelled form (no speaker) when `registry` has none.
	private static func paragraph(speaker: Int?, text: String, overlapping: Bool, registry: SpeakerRegistry?) -> NotesSpeakerParagraph {
		let speaker = speaker.flatMap { registry?.speaker($0) }
		let remembered = speaker.map { $0.voiceprintID != nil && $0.voiceprintID != Voiceprint.userID } ?? false
		return NotesSpeakerParagraph(
			speaker: speaker?.id,
			label: speaker.map { registry!.label($0.id) },
			isUser: speaker?.voiceprintID == Voiceprint.userID,
			markedAsUser: speaker.map { $0.voiceprintID == Voiceprint.userID && !$0.fixed } ?? false,
			text: text,
			overlapping: overlapping,
			seconds: speaker.map { registry!.seconds(of: $0.id) } ?? 0,
			recognised: remembered && speaker?.fixed == true,
			voiceSaved: remembered && speaker?.fixed == false,
			voiceprintID: remembered ? speaker?.voiceprintID : nil
		)
	}

	/// The Transcript tab's sentences. Chips only when the session is labelled (`labelled`).
	private static func sentenceItems(
		_ transcript: NotesTranscript, sentences: [NotesSentence], timeline: [NotesTimelineSentence],
		labelled: Bool, registry: SpeakerRegistry?
	) -> [NotesSentenceItem] {
		let lines = Dictionary(transcript.lines.map { ($0.chunk, $0) }, uniquingKeysWith: { first, _ in first })
		return zip(sentences, timeline).map { sentence, placed in
			let turns = lines[sentence.point.chunk]?.turns
			let overlapping = turns.flatMap { $0.indices.contains(sentence.point.turn) ? $0[sentence.point.turn].isOverlapping : nil } ?? false
			return NotesSentenceItem(
				point: sentence.point,
				text: sentence.text,
				startsParagraph: sentence.point.sentence == 0,
				paragraph: paragraph(
					speaker: labelled ? sentence.speaker : nil, text: "", overlapping: overlapping, registry: labelled ? registry : nil
				),
				start: placed.start,
				end: placed.end,
				trimIndex: placed.trimIndex
			)
		}
	}

	func saveTranscript(_ id: String, text: String) throws {
		guard id != capturingID else { throw NotesError.recordingNow }
		let folder = folder(id)
		guard let session = sessions[id] ?? folder.loadManifest() else { return }
		// Only once the transcript is complete and no notes are being written from it.
		let idle = sessions[id] == nil || parked.contains(id)
		guard idle, session.stage == .done || session.stage == .noting else { throw NotesError.writingNotes }
		let transcript = (transcripts[id] ?? folder.transcript.load()).edited(text, registry: shownRegistry(id))
		try folder.transcript.commitEdit(transcript)
		if sessions[id] != nil { transcripts[id] = transcript }
		// The left-out stretches follow their sentences into the edited transcript; one whose first or last
		// sentence was edited is dropped.
		let before = folder.loadTrims()
		let trims = before.reanchored(to: transcript)
		if trims != before {
			do {
				try folder.saveTrims(trims)
			} catch {
				logger.error("Notes trims of \(id, privacy: .public) not saved after an edit: \(error.localizedDescription, privacy: .public)")
			}
		}
		// Parts written from the old transcript must not be reused.
		for part in folder.savedParts() {
			FileManager.default.removeItemIfExists(at: folder.partURL(part))
		}
		logger.notice("Notes transcript of \(id, privacy: .public) edited, \(transcript.lines.count) paragraphs")
		retryNotes(id)
	}

	/// Leaves a stretch out of the notes. Only the layer in `trims.json` changes; notes are written again on request.
	func leaveOut(_ id: String, from: NotesTrimPoint, to: NotesTrimPoint) throws {
		let folder = try trimmableFolder(id)
		var trims = folder.loadTrims()
		trims.leaveOut(from: from, to: to, in: transcripts[id] ?? folder.transcript.load())
		try folder.saveTrims(trims)
		logger.notice("Notes session \(id, privacy: .public): a stretch left out, \(trims.trims.count) in all")
		events.yield(.changed(id))
	}

	func bringBack(_ id: String, index: Int) throws {
		let folder = try trimmableFolder(id)
		var trims = folder.loadTrims()
		trims.bringBack(at: index)
		try folder.saveTrims(trims)
		logger.notice("Notes session \(id, privacy: .public): a stretch brought back, \(trims.trims.count) left")
		events.yield(.changed(id))
	}

	/// The session's folder, once its transcript is complete (notes being or already written).
	private func trimmableFolder(_ id: String) throws -> NotesSessionFolder {
		let folder = folder(id)
		guard id != capturingID, let session = sessions[id] ?? folder.loadManifest(),
		      session.stage == .noting || session.stage == .done else { throw NotesError.transcriptIncomplete }
		return folder
	}

	func delete(_ id: String) throws {
		guard id != capturingID else { throw NotesError.recordingNow }
		sessions[id] = nil
		transcripts[id] = nil
		registries[id] = nil
		parked.remove(id)
		progress[id] = nil
		try FileManager.default.removeItem(at: folder(id).url)
		logger.notice("Notes session \(id, privacy: .public) deleted")
		events.yield(.changed(id))
	}

	// MARK: - Voiceprint

	func enrolVoiceprint(history: [Transcript], progress: @escaping @Sendable (Double) -> Void) async throws -> Voiceprint {
		try await VoiceprintEnroller(store: voiceprints, splitter: speakers, voice: voice).enrolUser(history: history, progress: progress)
	}

	/// Enrols from recording files directly (the harness, which has no History of its own).
	func enrolVoiceprint(recordings: [URL]) async throws -> Voiceprint {
		try await VoiceprintEnroller(store: voiceprints, splitter: speakers, voice: voice)
			.enrolUser(recordings: VoiceprintEnroller.spread(recordings, count: VoiceprintEnroller.maxSources))
	}

	func voiceprint() -> Voiceprint? {
		voiceprints.load(Voiceprint.userID)
	}

	func deleteVoiceprint() throws {
		try voiceprints.delete(Voiceprint.userID)
		logger.notice("Voiceprint deleted")
	}

	// MARK: - Speaker names

	func nameSpeaker(_ id: String, speaker: Int, name: String, remember: Bool) throws {
		let folder = folder(id)
		guard var registry = registry(id) else { throw SpeakerNamingError.notRenamable }
		try SpeakerNaming.apply(name: name, to: speaker, remember: remember, registry: &registry, store: voiceprints)
		try folder.saveSpeakers(registry)
		if registries[id] != nil { registries[id] = registry }
		logger.notice("Notes session \(id, privacy: .public): speaker \(speaker) named\(registry.speaker(speaker)?.voiceprintID == nil ? "" : ", voice saved", privacy: .public)")
		events.yield(.changed(id))
	}

	func rememberedVoices() -> [Voiceprint] {
		voiceprints.all().filter { !$0.isUser }
	}

	func forgetRememberedVoice(_ voiceprintID: String) throws {
		guard voiceprintID != Voiceprint.userID else { return }
		try voiceprints.delete(voiceprintID)
		logger.notice("Remembered voice deleted")
	}

	private static func sessionIDs() -> [String] {
		let names = (try? FileManager.default.contentsOfDirectory(atPath: URL.notesFolderURL.path)) ?? []
		return names.filter { !$0.hasPrefix(".") }.sorted()
	}

	/// When the session last wrote anything: the end of a session a crash cut short.
	private static func lastWrite(in folder: NotesSessionFolder) -> Date? {
		let urls = [folder.transcript.currentURL] + folder.pendingChunks().map(folder.pendingChunkURL)
		return urls.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
	}

	/// The process's physical footprint, as Activity Monitor's Memory column shows it.
	static func footprint() -> UInt64 {
		var info = task_vm_info_data_t()
		var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
		let result = withUnsafeMutablePointer(to: &info) {
			$0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
				task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
			}
		}
		return result == KERN_SUCCESS ? info.phys_footprint : 0
	}
}
