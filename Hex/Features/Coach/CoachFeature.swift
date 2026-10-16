import ComposableArchitecture
import Foundation
import HexCore

/// The Speech Coach tab (P3.6 D6): how the user speaks, from History recordings Parakeet listens to again on
/// request, plus the filler-free minute. Layout C in `<data root>/bench/coach-mockups/`.
@Reducer
struct CoachFeature {
	@ObservableState
	struct State: Equatable {
		@Shared(.hexSettings) var hexSettings: HexSettings
		@Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
		@Shared(.sentEdits) var sentEdits: SentEditLog

		var clips: [CoachClip] = []
		var minutes: [CoachMinute] = []
		var summary = CoachSummary()
		/// Recordings the next Run analysis would do.
		var pending = 0
		var progress: CoachProgress?
		var runNote: String?
		/// Which snippet is playing (`Snippet.id`).
		var playing: String?
		var minute: MinuteSession?

		var bestMinute: CoachMinute? { CoachMinute.best(of: minutes) }
	}

	/// One go at the filler-free minute, shown as a sheet.
	struct MinuteSession: Equatable, Identifiable {
		enum Phase: Equatable {
			case ready
			case recording(startedAt: Date)
			case scoring
			case result(CoachMinute, previousBest: CoachMinute?)
			case failed(String)
		}

		var id = UUID()
		var topic: String
		var phase: Phase = .ready
		/// Kept until the sheet closes so the user can hear the minute back; never saved.
		var audio: URL?
	}

	/// A moment to play: a dictation's recording, the time in it, and its length when it's played whole.
	struct Snippet: Equatable {
		var dictationID: UUID
		var time: Double
		var seconds: Double?
		var id: String { "\(dictationID.uuidString)@\(time)" }

		/// Where playback starts and for how long: a whole moment with a little air around it, or a few
		/// seconds around a point.
		var playback: (from: Double, seconds: Double) {
			if let seconds { return (time - SnippetPlayer.wholeLeadIn, seconds + SnippetPlayer.wholeLeadIn + SnippetPlayer.wholeTail) }
			return (time - SnippetPlayer.leadIn, SnippetPlayer.snippetSeconds)
		}
	}

	enum Action: BindableAction {
		case binding(BindingAction<State>)
		case task
		case loaded(clips: [CoachClip], minutes: [CoachMinute], pending: Int)
		case runAnalysis
		case stopAnalysis
		case progress(CoachProgress)
		case runFinished(String?)
		case play(Snippet)
		case playMinute
		case playFinished(String)
		case stopPlaying
		case startMinute
		case toggleMinuteRecording
		case minuteRecorded(URL)
		case minuteScored(Result<CoachMinute, Error>)
		case anotherTopic
		case closeMinute
		case setStutterFriendly(Bool)
	}

	private enum CancelID { case analysis, playback, minute }

	@Dependency(\.coach) var coach
	@Dependency(\.recording) var recording
	@Dependency(\.soundEffects) var soundEffects
	@Dependency(\.date.now) var now
	@Dependency(\.continuousClock) var clock
	@Dependency(\.withRandomNumberGenerator) var withRandomNumberGenerator

	var body: some ReducerOf<Self> {
		BindingReducer()

		Reduce { state, action in
			switch action {
			case .binding:
				return .none

			case .task:
				return load(state)

			case let .loaded(clips, minutes, pending):
				state.clips = clips
				state.minutes = minutes
				state.pending = pending
				summarize(&state)
				return .none

			case .runAnalysis:
				guard state.progress == nil else { return .none }
				state.progress = CoachProgress(done: 0, total: state.pending, failed: 0)
				state.runNote = nil
				let history = state.transcriptionHistory.history
				let edits = state.sentEdits.edits
				let model = state.hexSettings.selectedModel
				return .run { [coach] send in
					do {
						for try await progress in coach.analyse(history, edits, model) {
							await send(.progress(progress))
						}
						await send(.runFinished(nil))
					} catch is CancellationError {
						await send(.runFinished(nil))
					} catch {
						await send(.runFinished(error.localizedDescription))
					}
				}
				.cancellable(id: CancelID.analysis, cancelInFlight: true)

			case .stopAnalysis:
				return .merge(.cancel(id: CancelID.analysis), .send(.runFinished(nil)))

			case let .progress(progress):
				state.progress = progress
				return .none

			case let .runFinished(error):
				if let error {
					state.runNote = error
				} else if let progress = state.progress, progress.failed > 0 {
					state.runNote = "\(progress.failed) of \(progress.total) recordings couldn't be analysed."
				}
				state.progress = nil
				return load(state)

			case let .play(snippet):
				if case .recording = state.minute?.phase { return .none }
				guard let transcript = state.transcriptionHistory.history.first(where: { $0.id == snippet.dictationID }) else {
					return .none
				}
				state.playing = snippet.id
				let playback = snippet.playback
				return playEffect(id: snippet.id) { [coach] in
					try await coach.play(transcript.audioPath, playback.from, playback.seconds)
				}

			case .playMinute:
				guard let audio = state.minute?.audio else { return .none }
				state.playing = "minute"
				return playEffect(id: "minute") { [coach] in
					try await coach.play(audio, 0, CoachMinute.seconds + 5)
				}

			case let .playFinished(id):
				if state.playing == id { state.playing = nil }
				return .none

			case .stopPlaying:
				state.playing = nil
				return .cancel(id: CancelID.playback)

			case .startMinute:
				state.minute = MinuteSession(topic: randomTopic(excluding: nil))
				return .run { [recording] _ in await recording.warmUpRecorder() }

			case .toggleMinuteRecording:
				guard var session = state.minute else { return .none }
				switch session.phase {
				case .ready, .result, .failed:
					if let audio = session.audio { FileManager.default.removeItemIfExists(at: audio) }
					session.audio = nil
					session.phase = .recording(startedAt: now)
					state.minute = session
					// A playback still running would be recorded over the new take.
					state.playing = nil
					return .concatenate(.cancel(id: CancelID.playback), .run { [recording, soundEffects, clock] send in
						soundEffects.play(.startRecording)
						await recording.startRecording()
						try await clock.sleep(for: .seconds(CoachMinute.seconds))
						await send(.toggleMinuteRecording)
					}
					.cancellable(id: CancelID.minute, cancelInFlight: true))

				case .recording:
					session.phase = .scoring
					state.minute = session
					let topic = session.topic
					let model = state.hexSettings.selectedModel
					return .concatenate(
						.cancel(id: CancelID.minute),
						.run { [recording, soundEffects, coach] send in
							let stopped = await recording.stopRecording()
							soundEffects.play(.stopRecording)
							guard case let .captured(url) = stopped else {
								await send(.minuteScored(.failure(CoachMinuteError.nothingRecorded)))
								return
							}
							await send(.minuteRecorded(url))
							do {
								await send(.minuteScored(.success(try await coach.scoreMinute(url, topic, model))))
							} catch {
								await send(.minuteScored(.failure(error)))
							}
						}
					)

				case .scoring:
					return .none
				}

			case let .minuteRecorded(url):
				if state.minute == nil {
					// Closed while it was being saved.
					FileManager.default.removeItemIfExists(at: url)
				} else {
					state.minute?.audio = url
				}
				return .none

			case let .minuteScored(result):
				guard var session = state.minute else { return .none }
				switch result {
				case let .success(minute):
					session.phase = .result(minute, previousBest: state.bestMinute)
					state.minutes.append(minute)
				case let .failure(error):
					session.phase = .failed(error.localizedDescription)
				}
				state.minute = session
				return .none

			case .anotherTopic:
				guard var session = state.minute else { return .none }
				session.topic = randomTopic(excluding: session.topic)
				state.minute = session
				return .none

			case let .setStutterFriendly(isOn):
				state.$hexSettings.withLock { $0.coachStutterFriendly = isOn }
				summarize(&state)
				return .none

			case .closeMinute:
				let wasRecording: Bool
				if case .recording = state.minute?.phase { wasRecording = true } else { wasRecording = false }
				if let audio = state.minute?.audio { FileManager.default.removeItemIfExists(at: audio) }
				state.minute = nil
				state.playing = nil
				return .merge(
					.cancel(id: CancelID.minute),
					.cancel(id: CancelID.playback),
					wasRecording
						? .run { [recording] _ in
							if case let .captured(url) = await recording.stopRecording() {
								FileManager.default.removeItemIfExists(at: url)
							}
						}
						: .none
				)
			}
		}
	}

	private func load(_ state: State) -> Effect<Action> {
		let history = state.transcriptionHistory.history
		return .run { [coach] send in
			let clips = (try? await coach.clips()) ?? []
			let minutes = (try? await coach.minutes()) ?? []
			let pending = await coach.pending(history)
			await send(.loaded(clips: clips, minutes: minutes, pending: pending))
		}
	}

	private func summarize(_ state: inout State) {
		state.summary = CoachSummary(
			state.clips,
			now: now,
			stutterFriendly: state.hexSettings.coachStutterFriendly,
			vocabulary: state.hexSettings.vocabulary
		)
	}

	private func playEffect(id: String, _ play: @escaping @Sendable () async throws -> Void) -> Effect<Action> {
		.run { send in
			try? await play()
			await send(.playFinished(id))
		}
		.cancellable(id: CancelID.playback, cancelInFlight: true)
	}

	private func randomTopic(excluding current: String?) -> String {
		let choices = CoachMinute.topics.filter { $0 != current }
		return withRandomNumberGenerator { choices.randomElement(using: &$0) } ?? CoachMinute.topics[0]
	}
}

enum CoachMinuteError: LocalizedError {
	case nothingRecorded

	var errorDescription: String? {
		switch self {
		case .nothingRecorded: "Nothing was recorded. Check the microphone in Settings."
		}
	}
}
