import ComposableArchitecture
import Foundation
import HexCore
import WhisperKit

/// The Practice tab: short read-aloud sets, what dictations became when sent, vocabulary suggestions
/// from history (only when asked), and a research question about personalizing the models.
@Reducer
struct PracticeFeature {
	@ObservableState
	struct State: Equatable {
		@Shared(.hexSettings) var hexSettings: HexSettings
		@Shared(.sentEdits) var sentEdits: SentEditLog
		@Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
		@Shared(.practiceLog) var practiceLog: PracticeLog

		/// The read-aloud session while its sheet is open.
		var session: PracticeSession?
		/// Sizes of the files in the recordings folder, by name.
		var practiceFiles: [String: Int64] = [:]

		/// Nil until the user asks for a check.
		var suggestions: [VocabularySuggestion]?
		var isCheckingHistory = false
		var checkError: String?
		/// Which model answered the last check.
		var checkedWith: String?

		var research = ""
		var isResearching = false
		var researchError: String?

		/// "Check my recordings" in progress: lines done and to do.
		var recordingCheck: RecordingCheckProgress?
		var recordingCheckNote: String?
	}

	enum Action {
		case checkHistory
		case suggestionsLoaded([VocabularySuggestion], model: String)
		case checkFailed(String)
		case addSuggestion(VocabularySuggestion)
		case dismissSuggestion(VocabularySuggestion)
		case setCaptureSentEdits(Bool)
		case setResearchModel(String)
		case askResearch
		case researchProgress(String)
		case researchFinished
		case researchFailed(String)
		case cancelResearch

		case startSession(endless: Bool)
		case endSession
		/// The record button: start recording the current line, or stop and save it.
		case toggleRecording
		/// Space went down (repeats filtered out) or up: tap to start and stop, or hold to speak.
		case spaceDown
		case spaceUp
		case lineSaved(PracticeRecording)
		case lineFailed(String)
		case skipLine
		/// Record the previous line again.
		case redoLast

		case scanPracticeFolder
		case practiceFolderScanned([String: Int64]?)
		case markTrained
		case clearTrainedAudio

		/// Transcribes each recording with a second engine family and grades it (`PracticeGrade`).
		case checkRecordings
		case recordingChecked(lineID: String, recognized: String?, secondOpinion: String?, engine: String?)
		case recordingCheckProgress(done: Int, total: Int)
		case recordingCheckFinished(note: String?)
		case cancelRecordingCheck
	}

	enum CancelID {
		case check
		case research
		case practiceLine
		case scan
		case recordingCheck
	}

	/// A history check sends up to ~14K characters; a fast model answers in a few seconds.
	static let checkTimeout: Double = 45
	/// Search models read several pages before answering.
	static let researchTimeout: Double = 240

	@Dependency(\.rewrite) var rewrite
	@Dependency(\.keychain) var keychain
	@Dependency(\.recording) var recording
	@Dependency(\.transcription) var transcription
	@Dependency(\.soundEffects) var soundEffects
	@Dependency(\.date.now) var now
	@Dependency(\.withRandomNumberGenerator) var withRandomNumberGenerator

	var body: some ReducerOf<Self> {
		Reduce { state, action in
			switch action {
			case .checkHistory:
				let pairs = VocabularySuggester.pairs(
					history: state.transcriptionHistory.history,
					sentEdits: state.sentEdits.edits
				)
				state.checkError = nil
				guard !pairs.isEmpty else {
					state.suggestions = []
					state.checkError = "Nothing to check yet: no dictation has been rewritten or edited."
					return .none
				}
				state.isCheckingHistory = true
				let settings = state.hexSettings
				let messages = VocabularySuggester.messages(pairs: pairs, vocabulary: settings.vocabulary)
				var endpoints: [(RewriteEndpointRole, RewriteEndpoint)] = [(.primary, settings.rewritePrimary)]
				if settings.rewriteFallbackEnabled {
					endpoints.append((.fallback, settings.rewriteFallback))
				}
				return .run { [rewrite, keychain] send in
					var failures: [String] = []
					for (role, endpoint) in endpoints where endpoint.isConfigured {
						var endpoint = endpoint
						endpoint.timeout = max(endpoint.timeout, Self.checkTimeout)
						do {
							let answer = try await rewrite.complete(endpoint, keychain.read(endpoint.keychainAccount(role)), messages)
							if let suggestions = VocabularySuggester.parse(answer, vocabulary: settings.vocabulary) {
								await send(.suggestionsLoaded(suggestions, model: endpoint.model))
								return
							}
							failures.append("\(endpoint.model): the answer wasn't a list")
						} catch {
							failures.append("\(endpoint.model): \(error.localizedDescription)")
						}
					}
					await send(.checkFailed(failures.joined(separator: "\n")))
				}
				.cancellable(id: CancelID.check, cancelInFlight: true)

			case let .suggestionsLoaded(suggestions, model):
				state.isCheckingHistory = false
				state.suggestions = suggestions
				state.checkedWith = model
				HexLog.learning.info("History check by \(model, privacy: .public): \(suggestions.count) suggestions")
				return .none

			case let .checkFailed(message):
				state.isCheckingHistory = false
				state.checkError = message
				return .none

			case let .addSuggestion(suggestion):
				state.$hexSettings.withLock { settings in
					if !settings.vocabulary.contains(where: { $0.caseInsensitiveCompare(suggestion.term) == .orderedSame }) {
						settings.vocabulary.append(suggestion.term)
					}
				}
				state.suggestions?.removeAll { $0.id == suggestion.id }
				return .none

			case let .dismissSuggestion(suggestion):
				state.suggestions?.removeAll { $0.id == suggestion.id }
				return .none

			case let .setCaptureSentEdits(enabled):
				state.$hexSettings.withLock { $0.captureSentEdits = enabled }
				return .none

			case let .setResearchModel(model):
				state.$hexSettings.withLock { $0.practiceResearchModel = model }
				return .none

			case .askResearch:
				let settings = state.hexSettings
				let model = settings.practiceResearchModel.trimmingCharacters(in: .whitespaces)
				var endpoint = settings.rewritePrimary
				// A search model is a router feature (OmniRoute's wp-search); other providers use their rewrite model.
				if endpoint.provider == .custom, !model.isEmpty {
					endpoint.model = model
				}
				endpoint.timeout = Self.researchTimeout
				endpoint.reasoningEffort = ""
				let edits = state.sentEdits.edits
				let messages = PracticeResearch.messages(.init(
					dictations: state.transcriptionHistory.history.count,
					sentEdits: edits.count,
					editedSentEdits: edits.filter(\.wasEdited).count,
					engine: settings.selectedModel
				))
				state.research = ""
				state.researchError = nil
				state.isResearching = true
				return .run { [rewrite, keychain] send in
					do {
						for try await text in rewrite.stream(endpoint, keychain.read(endpoint.keychainAccount(.primary)), messages) {
							await send(.researchProgress(text))
						}
						await send(.researchFinished)
					} catch is CancellationError {
						await send(.researchFinished)
					} catch {
						await send(.researchFailed("\(endpoint.model): \(error.localizedDescription)"))
					}
				}
				.cancellable(id: CancelID.research, cancelInFlight: true)

			case let .researchProgress(text):
				state.research = text
				return .none

			case .researchFinished:
				state.isResearching = false
				if state.research.isEmpty {
					state.researchError = "The model returned no text."
				}
				return .none

			case let .researchFailed(message):
				state.isResearching = false
				state.researchError = message
				return .none

			case .cancelResearch:
				state.isResearching = false
				return .cancel(id: CancelID.research)

			case .startSession, .endSession, .toggleRecording, .spaceDown, .spaceUp, .lineSaved, .lineFailed, .skipLine, .redoLast:
				return reduceSession(&state, action)

			case .scanPracticeFolder, .practiceFolderScanned, .markTrained, .clearTrainedAudio:
				return reduceStorage(&state, action)

			case .checkRecordings, .recordingChecked, .recordingCheckProgress, .recordingCheckFinished, .cancelRecordingCheck:
				return reduceRecordingCheck(&state, action)
			}
		}
	}
}

// MARK: - Read-aloud session

/// One sitting of read-aloud practice: a set of up to ten lines, or endless. Each line is saved as soon
/// as it's read, so ending the session at any point keeps everything recorded so far.
struct PracticeSession: Equatable, Identifiable {
	enum Phase: Equatable {
		case ready
		case recording(startedAt: Date)
		case saving
	}

	var id = UUID()
	var isEndless: Bool
	/// The set's lines, or in endless mode every line shown so far.
	var picks: [PracticePick]
	var index = 0
	/// A line being read again, ahead of `picks[index]`.
	var redo: PracticePick?
	var phase: Phase = .ready
	/// The line just saved, with what the engine heard.
	var lastRecording: PracticeRecording?
	var error: String?
	/// Word error rate per line recorded in this sitting (nil if the engine failed).
	var results: [String: Double?] = [:]
	var spaceKey = PracticeSpaceKey()

	var isRecording: Bool {
		if case .recording = phase { true } else { false }
	}

	/// Nil when the set is done, or in endless mode when every line is recorded.
	var current: PracticePick? {
		redo ?? (picks.indices.contains(index) ? picks[index] : nil)
	}

	var perfectCount: Int {
		results.values.filter { $0 == 0 }.count
	}
}

extension PracticeFeature {
	func reduceSession(_ state: inout State, _ action: Action) -> Effect<Action> {
		let script = PracticeScript.bundled
		switch action {
		case let .startSession(endless):
			let log = state.practiceLog
			let picks = withRandomNumberGenerator { generator in
				endless
					? PracticePicker.pickNext(script: script, log: log, after: [], using: &generator).map { [$0] } ?? []
					: PracticePicker.pickSet(script: script, log: log, using: &generator)
			}
			var session = PracticeSession(isEndless: endless, picks: picks)
			// "Another set" keeps the sheet open.
			session.id = state.session?.id ?? session.id
			state.session = session
			markShown(&state)
			return .run { [recording] _ in await recording.warmUpRecorder() }

		case .endSession:
			let wasRecording: Bool
			if case .recording = state.session?.phase { wasRecording = true } else { wasRecording = false }
			state.session = nil
			guard wasRecording else { return .none }
			return .merge(
				.cancel(id: CancelID.practiceLine),
				.run { [recording] _ in
					if case let .captured(url) = await recording.stopRecording() {
						FileManager.default.removeItemIfExists(at: url)
					}
				}
			)

		case .toggleRecording:
			guard var session = state.session, let line = session.current?.line else { return .none }
			switch session.phase {
			case .ready:
				session.phase = .recording(startedAt: now)
				session.error = nil
				state.session = session
				return .merge(
					.run { [recording, soundEffects] _ in
						soundEffects.play(.startRecording)
						await recording.startRecording()
					}
					.cancellable(id: CancelID.practiceLine, cancelInFlight: true),
					.run { [transcription, model = state.hexSettings.selectedModel] _ in
						await transcription.prewarm(model)
					}
				)

			case let .recording(startedAt):
				session.phase = .saving
				state.session = session
				let elapsed = now.timeIntervalSince(startedAt)
				let model = state.hexSettings.selectedModel
				let date = now
				return .run { [recording, transcription, soundEffects] send in
					let stopped = await recording.stopRecording()
					soundEffects.play(.stopRecording)
					guard case let .captured(captured) = stopped else {
						await send(.lineFailed("Nothing was recorded. Check the microphone in Settings."))
						return
					}
					do {
						let folder = URL.practiceFolderURL
						try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
						let audio = folder.appending(component: "\(line.id).wav")
						let kept = try PracticeAudio.saveTrimmed(from: captured, to: audio)
						// The reference transcript next to the audio: an lsbench fixture.
						try line.text.write(to: folder.appending(component: "\(line.id).txt"), atomically: true, encoding: .utf8)

						var recognized: String?
						do {
							let options = DecodingOptions(language: "en", detectLanguage: false, chunkingStrategy: .vad)
							recognized = try await transcription.transcribe(audio, model, options) { _ in }
						} catch {
							HexLog.learning.error("Practice transcription failed: \(error.localizedDescription, privacy: .public)")
						}
						await send(.lineSaved(PracticeRecording(
							lineID: line.id,
							text: line.text,
							audioFileName: audio.lastPathComponent,
							recordedAt: date,
							duration: kept ?? elapsed,
							recognized: recognized,
							engine: model,
							wordErrorRate: recognized.map { WordErrorRate.rate(reference: line.text, hypothesis: $0) }
						)))
					} catch {
						FileManager.default.removeItemIfExists(at: captured)
						await send(.lineFailed("Couldn't save the recording: \(error.localizedDescription)"))
					}
				}
				.cancellable(id: CancelID.practiceLine, cancelInFlight: true)

			case .saving:
				return .none
			}

		case .spaceDown:
			guard var session = state.session else { return .none }
			let command = session.spaceKey.keyDown(
				isRecording: session.isRecording,
				canStart: session.phase == .ready && session.current != nil,
				at: now
			)
			state.session = session
			return command == .none ? .none : reduceSession(&state, .toggleRecording)

		case .spaceUp:
			guard var session = state.session else { return .none }
			let command = session.spaceKey.keyUp(isRecording: session.isRecording, at: now)
			state.session = session
			return command == .none ? .none : reduceSession(&state, .toggleRecording)

		case let .lineSaved(recording):
			state.$practiceLog.withLock { log in
				log.recordings[recording.lineID] = recording
				log.skipped.remove(recording.lineID)
				log.seen.insert(recording.lineID)
			}
			guard state.session != nil else { return .send(.scanPracticeFolder) }
			state.session?.lastRecording = recording
			state.session?.results[recording.lineID] = .some(recording.wordErrorRate)
			state.session?.phase = .ready
			advance(&state, script: script)
			return .send(.scanPracticeFolder)

		case let .lineFailed(message):
			state.session?.phase = .ready
			state.session?.error = message
			return .none

		case .skipLine:
			guard let session = state.session, session.phase == .ready, let pick = session.current else { return .none }
			// Skipping a redo keeps the recording it was redoing.
			if session.redo == nil {
				state.$practiceLog.withLock { _ = $0.skipped.insert(pick.id) }
			}
			advance(&state, script: script)
			return .none

		case .redoLast:
			guard let session = state.session, session.phase == .ready, session.redo == nil,
			      let last = session.lastRecording,
			      let line = script.line(id: last.lineID)
			else { return .none }
			let role = session.picks.first { $0.id == line.id }?.role ?? line.stage
			state.session?.redo = PracticePick(role: role, line: line)
			state.session?.lastRecording = nil
			return .none

		default:
			return .none
		}
	}

	/// Moves past the current line; in endless mode, picks the next one.
	private func advance(_ state: inout State, script: PracticeScript) {
		guard var session = state.session else { return }
		if session.redo != nil {
			session.redo = nil
		} else {
			session.index += 1
		}
		if session.isEndless, session.index == session.picks.count {
			let log = state.practiceLog
			let picks = session.picks
			if let next = withRandomNumberGenerator({ PracticePicker.pickNext(script: script, log: log, after: picks, using: &$0) }) {
				session.picks.append(next)
			}
		}
		state.session = session
		markShown(&state)
	}

	/// A line on screen counts as seen, so later sets start with lines not shown yet.
	private func markShown(_ state: inout State) {
		guard let id = state.session?.current?.id else { return }
		state.$practiceLog.withLock { _ = $0.seen.insert(id) }
	}
}

// MARK: - Recordings on disk

extension PracticeFeature {
	func reduceStorage(_ state: inout State, _ action: Action) -> Effect<Action> {
		switch action {
		case .scanPracticeFolder:
			return .run { send in
				await send(.practiceFolderScanned(PracticeAudio.scan(.practiceFolderURL)))
			}
			.cancellable(id: CancelID.scan, cancelInFlight: true)

		case let .practiceFolderScanned(files):
			guard let files else { return .none }
			state.practiceFiles = files
			let dropped = state.$practiceLog.withLock { $0.dropMissingAudio(present: Set(files.keys)) }
			if dropped > 0 {
				HexLog.learning.notice("Dropped \(dropped) practice recordings whose audio is missing")
			}
			return .none

		case .markTrained:
			let date = now
			state.$practiceLog.withLock { log in
				for recording in log.untrained {
					log.recordings[recording.lineID]?.trainedAt = date
				}
			}
			return .none

		case .clearTrainedAudio:
			let recordings = state.practiceLog.trainedWithAudio
			guard !recordings.isEmpty else { return .none }
			// Flagged before the files go, so a scan in between doesn't take them for lost recordings.
			let date = now
			state.$practiceLog.withLock { log in
				for recording in recordings {
					log.recordings[recording.lineID]?.audioClearedAt = date
				}
			}
			return .run { send in
				PracticeAudio.delete(recordings, in: .practiceFolderURL)
				await send(.scanPracticeFolder)
			}

		default:
			return .none
		}
	}
}

// MARK: - Recording check

struct RecordingCheckProgress: Equatable {
	var done: Int
	var total: Int
}

extension PracticeFeature {
	/// The engine whose opinion counts as independent: Cohere and Parakeet were trained apart, so a word both
	/// hear the same way is most likely what was said. Parakeet's own variants share their mistakes.
	static func secondOpinionEngine(for engine: String) -> String {
		CohereModel(rawValue: engine) != nil ? ParakeetModel.multilingualV3.identifier : CohereModel.fourBit.identifier
	}

	func reduceRecordingCheck(_ state: inout State, _ action: Action) -> Effect<Action> {
		switch action {
		case .checkRecordings:
			guard state.recordingCheck == nil else { return .none }
			let engine = state.hexSettings.selectedModel
			let other = Self.secondOpinionEngine(for: engine)
			let recordings = state.practiceLog.recordings.values
				.filter { $0.hasAudio && ($0.recognized == nil || $0.secondOpinionEngine != other) }
				.sorted { $0.lineID < $1.lineID }
			guard !recordings.isEmpty else {
				state.recordingCheckNote = state.practiceLog.recordings.isEmpty ? "Record a few lines first." : nil
				return .none
			}
			state.recordingCheck = RecordingCheckProgress(done: 0, total: recordings.count)
			state.recordingCheckNote = nil
			return .run { [transcription] send in
				let options = DecodingOptions(language: "en", detectLanguage: false, chunkingStrategy: .vad)
				let hasOther = await transcription.isModelDownloaded(other)
				for (index, recording) in recordings.enumerated() {
					try Task.checkCancellation()
					let audio = URL.practiceFolderURL.appending(component: recording.audioFileName)
					guard FileManager.default.fileExists(atPath: audio.path) else { continue }
					var recognized = recording.recognized
					if recognized == nil {
						recognized = try? await transcription.transcribe(audio, recording.engine, options) { _ in }
					}
					var secondOpinion: String?
					if hasOther {
						secondOpinion = try? await transcription.transcribe(audio, other, options) { _ in }
					}
					await send(.recordingChecked(
						lineID: recording.lineID, recognized: recognized, secondOpinion: secondOpinion,
						engine: secondOpinion == nil ? nil : other
					))
					await send(.recordingCheckProgress(done: index + 1, total: recordings.count))
				}
				await transcription.prewarm(engine)
				await send(.recordingCheckFinished(note: hasOther ? nil : "Download \(ParakeetModel(rawValue: other) != nil ? "Parakeet v3" : "Cohere Transcribe") in Settings for a second opinion. Without one, every word heard differently counts against the engine, even ones you read differently."))
			} catch: { error, send in
				await send(.recordingCheckFinished(note: error is CancellationError ? nil : error.localizedDescription))
			}
			.cancellable(id: CancelID.recordingCheck, cancelInFlight: true)

		case let .recordingChecked(lineID, recognized, secondOpinion, engine):
			state.$practiceLog.withLock { log in
				guard var recording = log.recordings[lineID] else { return }
				if let recognized, recording.recognized == nil {
					recording.recognized = recognized
					recording.wordErrorRate = WordErrorRate.rate(reference: recording.text, hypothesis: recognized)
				}
				if let secondOpinion, let engine {
					recording.secondOpinion = secondOpinion
					recording.secondOpinionEngine = engine
				}
				log.recordings[lineID] = recording
			}
			return .none

		case let .recordingCheckProgress(done, total):
			if state.recordingCheck != nil { state.recordingCheck = RecordingCheckProgress(done: done, total: total) }
			return .none

		case let .recordingCheckFinished(note):
			state.recordingCheck = nil
			state.recordingCheckNote = note
			return .none

		case .cancelRecordingCheck:
			state.recordingCheck = nil
			return .cancel(id: CancelID.recordingCheck)

		default:
			return .none
		}
	}
}
