import ComposableArchitecture
import Foundation
import HexCore
import WhisperKit

/// The Practice tab: what dictations became when sent, vocabulary suggestions from history (only when
/// asked), and a research question about personalizing the models, answered through OmniRoute.
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

		/// Nil until the user asks for a check.
		var suggestions: [VocabularySuggestion]?
		var isCheckingHistory = false
		var checkError: String?
		/// Which model answered the last check.
		var checkedWith: String?

		var research = ""
		var isResearching = false
		var researchError: String?
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

		case startSession
		case endSession
		/// Space: start recording the current line, or stop and save it.
		case toggleRecording
		case lineSaved(PracticeRecording)
		case lineFailed(String)
		case skipLine
		/// Record the previous line again.
		case redoLast
	}

	enum CancelID {
		case check
		case research
		case practiceLine
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
							let answer = try await rewrite.complete(endpoint, keychain.read(role.keychainAccount), messages)
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
				endpoint.model = model.isEmpty ? endpoint.model : model
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
						for try await text in rewrite.stream(endpoint, keychain.read(RewriteEndpointRole.primary.keychainAccount), messages) {
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

			case .startSession, .endSession, .toggleRecording, .lineSaved, .lineFailed, .skipLine, .redoLast:
				return reduceSession(&state, action)
			}
		}
	}
}

// MARK: - Read-aloud session

/// One sitting of read-aloud practice. Each line is saved as soon as it's read, so ending the session at
/// any point keeps everything recorded so far.
struct PracticeSession: Equatable, Identifiable {
	enum Phase: Equatable {
		case ready
		case recording(startedAt: Date)
		case saving
	}

	let id = UUID()
	/// Nil when every line is recorded or skipped.
	var line: PracticeLine?
	var phase: Phase = .ready
	/// The line just saved, with what the engine heard.
	var lastRecording: PracticeRecording?
	var error: String?
	/// Lines recorded in this sitting.
	var recordedCount = 0
}

extension PracticeFeature {
	func reduceSession(_ state: inout State, _ action: Action) -> Effect<Action> {
		let script = PracticeScript.bundled
		switch action {
		case .startSession:
			state.session = PracticeSession(line: state.practiceLog.nextLine(in: script))
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
			guard var session = state.session, let line = session.line else { return .none }
			switch session.phase {
			case .ready:
				session.phase = .recording(startedAt: now)
				session.error = nil
				state.session = session
				return .run { [recording, soundEffects] _ in
					soundEffects.play(.startRecording)
					await recording.startRecording()
				}
				.cancellable(id: CancelID.practiceLine, cancelInFlight: true)

			case let .recording(startedAt):
				session.phase = .saving
				state.session = session
				let duration = now.timeIntervalSince(startedAt)
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
						FileManager.default.removeItemIfExists(at: audio)
						try FileManager.default.moveItem(at: captured, to: audio)
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
							duration: duration,
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

		case let .lineSaved(recording):
			state.$practiceLog.withLock { log in
				log.recordings[recording.lineID] = recording
				log.skipped.remove(recording.lineID)
			}
			guard var session = state.session else { return .none }
			session.lastRecording = recording
			session.recordedCount += 1
			session.phase = .ready
			session.line = state.practiceLog.nextLine(in: script)
			state.session = session
			return .none

		case let .lineFailed(message):
			state.session?.phase = .ready
			state.session?.error = message
			return .none

		case .skipLine:
			guard let session = state.session, session.phase == .ready, let line = session.line else { return .none }
			state.$practiceLog.withLock { _ = $0.skipped.insert(line.id) }
			let next = state.practiceLog.nextLine(in: script)
			state.session?.line = next
			return .none

		case .redoLast:
			guard let session = state.session, session.phase == .ready,
			      let last = session.lastRecording,
			      let line = script.lines.first(where: { $0.id == last.lineID })
			else { return .none }
			state.session?.line = line
			state.session?.lastRecording = nil
			return .none

		default:
			return .none
		}
	}
}
