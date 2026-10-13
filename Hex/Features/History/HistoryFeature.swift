import AVFoundation
import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import Inject
import SwiftUI
import WhisperKit

private let historyLogger = HexLog.history

// MARK: - Date Extensions

extension Date {
	func relativeFormatted() -> String {
		let calendar = Calendar.current
		let now = Date()
		
		if calendar.isDateInToday(self) {
			return "Today"
		} else if calendar.isDateInYesterday(self) {
			return "Yesterday"
		} else if let daysAgo = calendar.dateComponents([.day], from: self, to: now).day, daysAgo < 7 {
			let formatter = DateFormatter()
			formatter.dateFormat = "EEEE" // Day of week
			return formatter.string(from: self)
		} else {
			let formatter = DateFormatter()
			formatter.dateStyle = .medium
			formatter.timeStyle = .none
			return formatter.string(from: self)
		}
	}
}

// MARK: - Models

// MARK: - Storage Migration

extension URL {
	/// Where history was kept before scribe.sqlite (`TranscriptionHistoryKey`); imported once from here.
	static var transcriptionHistoryURL: URL {
		get {
			URL.hexMigratedFileURL(named: "transcription_history.json")
		}
	}
}

class AudioPlayerController: NSObject, AVAudioPlayerDelegate {
	private var player: AVAudioPlayer?
	private let (playbackFinishedStream, playbackFinishedContinuation) = AsyncStream<Void>.makeStream()

	func play(url: URL) throws {
		let player = try AVAudioPlayer(contentsOf: url)
		player.delegate = self
		self.player = player
		player.play()
	}

	/// Seconds into the recording, nil once playback is over.
	var currentTime: TimeInterval? {
		player?.currentTime
	}

	func stop() {
		player?.stop()
		player = nil
		finishPlayback()
	}

	func waitForPlaybackToFinish() async {
		for await _ in playbackFinishedStream {}
	}

	// AVAudioPlayerDelegate method
	func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
		guard self.player === player else { return }
		self.player = nil
		finishPlayback()
	}

	private func finishPlayback() {
		playbackFinishedContinuation.finish()
	}
}

// MARK: - History Feature

@Reducer
struct HistoryFeature {
	@ObservableState
	struct State: Equatable {
		@Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
		var playingTranscriptID: UUID?
		var playbackID: UUID?
		var audioPlayerController: AudioPlayerController?
		/// The playing entry's words placed in its recording, once known, and how far playback is.
		var playingWords: [SpokenWord]?
		var playbackTime: TimeInterval = 0
		/// Entries being retried, rewritten again or transcribed again.
		var working: Set<UUID> = []
		/// "Transcribe again" results, shown under their entry until replaced or dismissed.
		var alternates: [UUID: AlternateTranscript] = [:]
		/// Why the last redo of an entry didn't change it.
		var redoErrors: [UUID: String] = [:]
		/// Downloaded speech models, for "Transcribe again with".
		var engines: [HistoryEngine] = []

		mutating func stopAudioPlayback() {
			audioPlayerController?.stop()
			audioPlayerController = nil
			playingTranscriptID = nil
			playbackID = nil
			playingWords = nil
			playbackTime = 0
		}
	}

	enum Action {
		case playTranscript(UUID)
		case stopPlayback
		case copyToClipboard(String)
		case deleteTranscript(UUID)
		case deleteAllTranscripts
		case confirmDeleteAll
		case playbackFinished(UUID)
		/// The entry's word timings are known (nil: none, or they took too long); the audio starts now.
		case playbackReady(playbackID: UUID, [SpokenWord]?)
		case playbackProgressed(playbackID: UUID, TimeInterval)
		case navigateToSettings
		/// Transcribes a failed dictation's recording again with the current engine and rewrite, then copies it.
		case retryTranscript(UUID)
		case retryFinished(UUID)
		case task
		case enginesLoaded([HistoryEngine])
		/// Runs the heard words through the rewrite again in `mode`, with the current AI settings.
		case rewriteAgain(UUID, RewriteMode)
		/// Transcribes the recording with another downloaded engine; the result is shown, not applied.
		case transcribeAgain(UUID, engine: String)
		case redoFinished(UUID, RedoResult)
		case replaceWithAlternate(UUID)
		case dismissAlternate(UUID)
	}

	enum RedoResult: Equatable {
		case rewritten(TranscriptRewriter.Redo, source: String)
		case transcribed(AlternateTranscript)
		case failed(String)
	}

	enum PlaybackCancelID { case prepare }

	/// How long a first play waits for word timings (loading Parakeet) before it plays without highlighting.
	static let timingWait: Duration = .seconds(10)

	@Dependency(\.pasteboard) var pasteboard
	@Dependency(\.transcription) var transcription
	@Dependency(\.transcriptPersistence) var transcriptPersistence
	let rewriter = TranscriptRewriter()

	private func deleteAudioEffect(for transcripts: [Transcript]) -> Effect<Action> {
		.run { [transcriptPersistence] _ in
			for transcript in transcripts {
				try? await transcriptPersistence.deleteAudio(transcript)
			}
		}
	}

	var body: some ReducerOf<Self> {
		Reduce { state, action in
			switch action {
			case let .playTranscript(id):
				if state.playingTranscriptID == id {
					// Stop playback if tapping the same transcript
					state.stopAudioPlayback()
					return .cancel(id: PlaybackCancelID.prepare)
				}

				// Stop any existing playback
				state.stopAudioPlayback()

				guard let transcript = state.transcriptionHistory.history.first(where: { $0.id == id }) else {
					return .none
				}
				let playbackID = UUID()
				state.playingTranscriptID = id
				state.playbackID = playbackID

				@Shared(.hexSettings) var hexSettings: HexSettings
				let selectedModel = hexSettings.selectedModel
				// Highlight words as they're spoken: timings stored with the entry, or worked out now (Parakeet,
				// ~0.1 s per 10 s once loaded) and stored. The audio waits for them so the highlight starts with
				// the first word; after `timingWait` it plays without. The words are the ones heard, before any rewrite.
				return .run { [transcription] send in
					if let stored = try? ScribeStore.app.words(for: id) {
						await send(.playbackReady(playbackID: playbackID, stored))
						return
					}
					let words = (transcript.rawText ?? transcript.text).split(whereSeparator: \.isWhitespace).map(String.init)
					let timed = try? await withThrowingTaskGroup(of: [SpokenWord]?.self) { group in
						group.addTask {
							let timed = try await transcription.timedWords(transcript.audioPath, words, selectedModel)
							try? ScribeStore.app.saveWords(timed, for: id, source: "parakeet-tdt")
							return timed
						}
						group.addTask {
							try await Task.sleep(for: Self.timingWait)
							historyLogger.notice("Word timings took over \(Self.timingWait, privacy: .public); playing without highlighting")
							return nil
						}
						defer { group.cancelAll() }
						return try await group.next() ?? nil
					}
					await send(.playbackReady(playbackID: playbackID, timed ?? nil))
				}
				.cancellable(id: PlaybackCancelID.prepare, cancelInFlight: true)

			case let .playbackReady(playbackID, words):
				guard state.playbackID == playbackID,
				      let transcript = state.transcriptionHistory.history.first(where: { $0.id == state.playingTranscriptID })
				else { return .none }
				state.playingWords = words
				do {
					let controller = AudioPlayerController()
					try controller.play(url: transcript.audioPath)
					state.audioPlayerController = controller
					return .merge(
						.run { send in
							await controller.waitForPlaybackToFinish()
							await send(.playbackFinished(playbackID))
						},
						.run { send in
							while let time = controller.currentTime {
								await send(.playbackProgressed(playbackID: playbackID, time))
								try await Task.sleep(for: .milliseconds(50))
							}
						}
					)
				} catch {
					historyLogger.error("Failed to play audio: \(error.localizedDescription)")
					state.stopAudioPlayback()
					return .none
				}

			case .stopPlayback:
				state.stopAudioPlayback()
				return .none

			case let .playbackFinished(playbackID):
				guard state.playbackID == playbackID else { return .none }
				state.stopAudioPlayback()
				return .none

			case let .playbackProgressed(playbackID, time):
				guard state.playbackID == playbackID else { return .none }
				state.playbackTime = time
				return .none

			case let .copyToClipboard(text):
				return .run { [pasteboard] _ in
					await pasteboard.copy(text)
				}

			case let .deleteTranscript(id):
				guard let index = state.transcriptionHistory.history.firstIndex(where: { $0.id == id }) else {
					return .none
				}

				let transcript = state.transcriptionHistory.history[index]

				if state.playingTranscriptID == id {
					state.stopAudioPlayback()
				}

				_ = state.$transcriptionHistory.withLock { history in
					history.history.remove(at: index)
				}

				return deleteAudioEffect(for: [transcript])

			case .deleteAllTranscripts:
				return .send(.confirmDeleteAll)

			case .confirmDeleteAll:
				let transcripts = state.transcriptionHistory.history
				state.stopAudioPlayback()

				state.$transcriptionHistory.withLock { history in
					history.history.removeAll()
				}

				return deleteAudioEffect(for: transcripts)
				
			case let .retryTranscript(id):
				guard !state.working.contains(id),
				      let transcript = state.transcriptionHistory.history.first(where: { $0.id == id }),
				      transcript.failure != nil, transcript.audioRemoved != true
				else { return .none }
				state.working.insert(id)
				@Shared(.hexSettings) var hexSettings: HexSettings
				@Shared(.sentEdits) var sentEdits: SentEditLog
				let settings = hexSettings
				// The field the dictation was meant for is gone, so only the vocabulary and fixed spellings help.
				let biasing = BiasingContext.build(vocabulary: settings.vocabulary, sentEdits: sentEdits.edits, field: nil)
				let history = state.$transcriptionHistory
				return .run { [transcription, rewriter, pasteboard] send in
					let options = DecodingOptions(
						language: settings.outputLanguage,
						detectLanguage: settings.outputLanguage == nil,
						chunkingStrategy: .vad
					)
					let recognized = try await transcription.transcribe(transcript.audioPath, settings.selectedModel, options) { _ in }
					guard !recognized.isEmpty else { throw RetryFailure.nothingHeard }
					let redo = await rewriter.redo(
						recognized,
						mode: settings.rewriteMode,
						settings: settings,
						biasing: biasing,
						targetAppName: transcript.sourceAppName
					)
					history.withLock { history in
						guard let index = history.history.firstIndex(where: { $0.id == id }) else { return }
						history.history[index].text = redo.text
						history.history[index].rawText = redo.rawText
						history.history[index].rewriteMode = redo.rewriteMode
						history.history[index].rewrittenBy = redo.outcome?.rewrittenBy
						history.history[index].rewriteFailures = redo.outcome.flatMap { $0.failures.isEmpty ? nil : $0.failures }
						history.history[index].failure = nil
					}
					// The user has moved on from the field it was meant for, so it's copied, not pasted.
					await pasteboard.copy(redo.text)
					historyLogger.notice("Retried a failed dictation with \(settings.selectedModel, privacy: .public)")
					await send(.retryFinished(id))
				} catch: { error, send in
					historyLogger.error("Retry failed: \(error.localizedDescription, privacy: .public)")
					history.withLock { history in
						guard let index = history.history.firstIndex(where: { $0.id == id }) else { return }
						history.history[index].failure = error.localizedDescription
					}
					await send(.retryFinished(id))
				}

			case let .retryFinished(id):
				state.working.remove(id)
				return .none

			case .task:
				return .run { [transcription] send in
					var engines: [HistoryEngine] = []
					for model in CuratedModelLoader.load() where await transcription.isModelDownloaded(model.internalName) {
						engines.append(HistoryEngine(name: model.internalName, displayName: model.displayName))
					}
					await send(.enginesLoaded(engines))
				}

			case let .enginesLoaded(engines):
				state.engines = engines
				return .none

			case let .rewriteAgain(id, mode):
				guard !state.working.contains(id), mode.rewrites,
				      let transcript = state.transcriptionHistory.history.first(where: { $0.id == id }),
				      transcript.failure == nil
				else { return .none }
				state.working.insert(id)
				state.redoErrors[id] = nil
				@Shared(.hexSettings) var hexSettings: HexSettings
				@Shared(.sentEdits) var sentEdits: SentEditLog
				let settings = hexSettings
				let biasing = BiasingContext.build(vocabulary: settings.vocabulary, sentEdits: sentEdits.edits, field: nil)
				// The engine's words, not an earlier rewrite of them.
				let source = transcript.rawText ?? transcript.text
				return .run { [rewriter] send in
					let redo = await rewriter.redo(source, mode: mode, settings: settings, biasing: biasing, targetAppName: transcript.sourceAppName)
					if redo.rewriteMode == nil {
						let reasons = redo.outcome?.failures ?? []
						await send(.redoFinished(id, .failed(reasons.isEmpty ? "No rewrite AI is set up." : "Rewrite failed: \(reasons.joined(separator: "; "))")))
					} else {
						await send(.redoFinished(id, .rewritten(redo, source: source)))
					}
				}

			case let .transcribeAgain(id, engine):
				guard !state.working.contains(id),
				      let transcript = state.transcriptionHistory.history.first(where: { $0.id == id }),
				      transcript.audioRemoved != true
				else { return .none }
				state.working.insert(id)
				state.redoErrors[id] = nil
				state.alternates[id] = nil
				@Shared(.hexSettings) var hexSettings: HexSettings
				let language = hexSettings.outputLanguage
				let displayName = state.engines.first(where: { $0.name == engine })?.displayName ?? engine
				return .run { [transcription] send in
					let options = DecodingOptions(language: language, detectLanguage: language == nil, chunkingStrategy: .vad)
					let text = try await transcription.transcribe(transcript.audioPath, engine, options) { _ in }
					historyLogger.notice("Transcribed a history entry again with \(engine, privacy: .public)")
					await send(.redoFinished(id, .transcribed(AlternateTranscript(engine: displayName, text: text))))
				} catch: { error, send in
					historyLogger.error("Transcribe again with \(engine, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
					await send(.redoFinished(id, .failed(error.localizedDescription)))
				}

			case let .redoFinished(id, result):
				state.working.remove(id)
				switch result {
				case let .rewritten(redo, source):
					state.$transcriptionHistory.withLock { history in
						guard let index = history.history.firstIndex(where: { $0.id == id }) else { return }
						history.history[index].text = redo.text
						history.history[index].rawText = source
						history.history[index].rewriteMode = redo.rewriteMode
						history.history[index].rewrittenBy = redo.outcome?.rewrittenBy
						history.history[index].rewriteFailures = redo.outcome.flatMap { $0.failures.isEmpty ? nil : $0.failures }
					}
				case let .transcribed(alternate):
					state.alternates[id] = alternate
				case let .failed(message):
					state.redoErrors[id] = message
				}
				return .none

			case let .replaceWithAlternate(id):
				guard let alternate = state.alternates[id], !alternate.text.isEmpty else { return .none }
				state.alternates[id] = nil
				if state.playingTranscriptID == id { state.stopAudioPlayback() }
				// The new engine's words, as recognized: the old rewrite and its source no longer apply.
				state.$transcriptionHistory.withLock { history in
					guard let index = history.history.firstIndex(where: { $0.id == id }) else { return }
					history.history[index].text = alternate.text
					history.history[index].rawText = nil
					history.history[index].rewriteMode = nil
					history.history[index].rewrittenBy = nil
					history.history[index].rewriteFailures = nil
					history.history[index].failure = nil
				}
				// Word timings were placed for the old words; the next playback works them out again.
				return .run { _ in try? ScribeStore.app.saveWords([], for: id, source: "") }

			case let .dismissAlternate(id):
				state.alternates[id] = nil
				return .none

			case .navigateToSettings:
				// This will be handled by the parent reducer
				return .none
			}
		}
	}
}

/// The heard words with the one being spoken in the accent color; words already spoken in the primary
/// color, the rest secondary. Color only, so the text never reflows while it plays.
private struct KaraokeText: View {
	let words: [SpokenWord]
	let time: TimeInterval

	var body: some View {
		words.enumerated().reduce(Text("")) { text, item in
			let (index, word) = item
			let style: Color = time >= word.start && time < word.end ? .accentColor
				: time >= word.end ? .primary : .secondary
			return text + Text(index == 0 ? word.word : " " + word.word).foregroundColor(style)
		}
		.accessibilityLabel(words.map(\.word).joined(separator: " "))
	}
}

/// Which mode and model rewrote a transcript, why endpoints failed, and the text before the rewrite.
private struct RewriteDetailsView: View {
	let transcript: Transcript
	var onCopyOriginal: (String) -> Void = { _ in }
	@State private var showsOriginal = false

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 6) {
				if let mode = transcript.rewriteMode {
					Image(systemName: "wand.and.stars")
					Text(mode.displayName)
					if let model = transcript.rewrittenBy {
						Text("·")
						Text(model).textSelection(.enabled)
					}
					if let latency = transcript.latency, latency.rewriteMs > 0 {
						Text("·")
						Text("LLM \(Int(latency.rewriteMs.rounded())) ms")
					}
				} else {
					Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
					Text("Rewrite failed; pasted as recognized")
				}
				if let failures = transcript.rewriteFailures {
					Image(systemName: "info.circle")
						.help(failures.joined(separator: "\n"))
				}
				Spacer()
				if let rawText = transcript.rawText {
					Button("Copy original") { onCopyOriginal(rawText) }
						.buttonStyle(.link)
						.help("Copy the text as recognized, before the rewrite")
					Button(showsOriginal ? "Hide original" : "Show original") { showsOriginal.toggle() }
						.buttonStyle(.link)
				}
			}
			.font(.caption)
			.foregroundStyle(.secondary)

			if showsOriginal, let rawText = transcript.rawText {
				Text(rawText)
					.font(.callout)
					.foregroundStyle(.secondary)
					.textSelection(.enabled)
					.fixedSize(horizontal: false, vertical: true)
			}
			if let failures = transcript.rewriteFailures, transcript.rewriteMode == nil {
				Text(failures.joined(separator: "\n"))
					.font(.caption2)
					.foregroundStyle(.secondary)
					.textSelection(.enabled)
			}
		}
	}
}

/// What another engine heard in the recording, with Replace and Copy. Nothing changes until Replace.
private struct AlternateTranscriptView: View {
	let alternate: AlternateTranscript
	let onReplace: () -> Void
	let onCopy: () -> Void
	let onDismiss: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				Image(systemName: "waveform")
				Text(alternate.engine)
				Spacer()
				if !alternate.text.isEmpty {
					Button("Replace", action: onReplace)
						.help("Use this transcript for the entry (as recognized, without a rewrite)")
				}
				Button("Copy", action: onCopy)
				Button(action: onDismiss) {
					Image(systemName: "xmark")
				}
				.buttonStyle(.plain)
				.help("Dismiss")
			}
			.font(.caption)
			.foregroundStyle(.secondary)
			Text(alternate.text.isEmpty ? "No speech recognized." : alternate.text)
				.font(.callout)
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(8)
		.background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
	}
}

/// A dictation the engine couldn't transcribe: why, and Retry while its recording is kept.
private struct FailedTranscriptView: View {
	let failure: String
	let canRetry: Bool
	let isRetrying: Bool
	let onRetry: () -> Void

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Image(systemName: "exclamationmark.triangle.fill")
				.foregroundStyle(.orange)
			VStack(alignment: .leading, spacing: 2) {
				Text("Transcription failed")
				Text(failure)
					.font(.caption)
					.foregroundStyle(.secondary)
					.textSelection(.enabled)
			}
			Spacer()
			if isRetrying {
				ProgressView()
					.controlSize(.small)
			} else if canRetry {
				Button("Retry", action: onRetry)
					.help("Transcribe the recording again with the current model and copy the result")
			}
		}
	}
}

struct TranscriptView: View {
	let transcript: Transcript
	let isPlaying: Bool
	/// While playing: the words as heard, placed in the recording, and the playback position.
	var playingWords: [SpokenWord]? = nil
	var playbackTime: TimeInterval = 0
	/// Play was pressed and the word timings are being worked out before the audio starts.
	var isPreparingPlayback = false
	/// Retry, rewrite again or transcribe again is running.
	var isWorking = false
	var alternate: AlternateTranscript? = nil
	var redoError: String? = nil
	/// Downloaded engines for "Transcribe again with".
	var engines: [HistoryEngine] = []
	let onPlay: () -> Void
	let onCopy: () -> Void
	let onDelete: () -> Void
	/// Redo actions (retry, rewrite again, transcribe again, the alternate's buttons, copy original).
	var send: (HistoryFeature.Action) -> Void = { _ in }

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Group {
				if let failure = transcript.failure {
					FailedTranscriptView(
						failure: failure,
						canRetry: transcript.audioRemoved != true,
						isRetrying: isWorking,
						onRetry: { send(.retryTranscript(transcript.id)) }
					)
				} else if isPlaying, let playingWords, !playingWords.isEmpty {
					KaraokeText(words: playingWords, time: playbackTime)
				} else {
					Text(transcript.text)
				}
			}
				.font(.body)
				.lineLimit(nil)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.trailing, 40) // Space for buttons
				.padding(12)

			if transcript.rewriteMode != nil || transcript.rewriteFailures != nil {
				RewriteDetailsView(transcript: transcript, onCopyOriginal: { send(.copyToClipboard($0)) })
					.padding(.horizontal, 12)
					.padding(.bottom, 8)
			}

			if let redoError {
				Label(redoError, systemImage: "exclamationmark.triangle.fill")
					.font(.caption)
					.foregroundStyle(.orange)
					.textSelection(.enabled)
					.padding(.horizontal, 12)
					.padding(.bottom, 8)
			}

			if let alternate {
				AlternateTranscriptView(
					alternate: alternate,
					onReplace: { send(.replaceWithAlternate(transcript.id)) },
					onCopy: { send(.copyToClipboard(alternate.text)) },
					onDismiss: { send(.dismissAlternate(transcript.id)) }
				)
				.padding(.horizontal, 12)
				.padding(.bottom, 8)
			}

			Divider()

			HStack {
				HStack(spacing: 6) {
					// App icon and name
					if let bundleID = transcript.sourceAppBundleID,
					   let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
						Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
							.resizable()
							.frame(width: 14, height: 14)
						if let appName = transcript.sourceAppName {
							Text(appName)
						}
						Text("•")
					}
					
					Image(systemName: "clock")
					Text(transcript.timestamp.relativeFormatted())
					Text("•")
					Text(transcript.timestamp.formatted(date: .omitted, time: .shortened))
					Text("•")
					Text(String(format: "%.1fs", transcript.duration))
					if let latency = transcript.latency {
						Text("•")
						Text("\(Int(latency.totalMs.rounded())) ms")
							.help("Key release to paste: \(latency.summary)")
					}
				}
				.font(.subheadline)
				.foregroundStyle(.secondary)

				Spacer()

				HStack(spacing: 10) {
					if isWorking, transcript.failure == nil {
						ProgressView()
							.controlSize(.mini)
					}
					if transcript.failure == nil {
						Button {
							onCopy()
							showCopyAnimation()
						} label: {
							HStack(spacing: 4) {
								Image(systemName: showCopied ? "checkmark" : "doc.on.doc.fill")
								if showCopied {
									Text("Copied").font(.caption)
								}
							}
						}
						.buttonStyle(.plain)
						.foregroundStyle(showCopied ? .green : .secondary)
						.help("Copy to clipboard")
					}

					if transcript.audioRemoved == true {
						Image(systemName: "play.slash")
							.foregroundStyle(.tertiary)
							.help("Recording deleted (Settings > History > Keep Recordings); the text is kept")
					} else {
						if isPreparingPlayback {
							ProgressView()
								.controlSize(.mini)
								.help("Placing the words in the recording; playback starts in a moment")
						}
						Button(action: onPlay) {
							Image(systemName: isPlaying ? "stop.fill" : "play.fill")
						}
						.buttonStyle(.plain)
						.foregroundStyle(isPlaying ? .blue : .secondary)
						.help(isPlaying ? "Stop playback" : "Play audio")
					}

					Button(action: onDelete) {
						Image(systemName: "trash.fill")
					}
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
					.help("Delete transcript")
				}
				.font(.subheadline)
			}
			.frame(height: 20)
			.padding(.horizontal, 12)
			.padding(.vertical, 6)
		}
		.background(
			RoundedRectangle(cornerRadius: 8)
				.fill(Color(.windowBackgroundColor).opacity(0.5))
				.overlay(
					RoundedRectangle(cornerRadius: 8)
						.strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
				)
		)
		.contextMenu { redoMenu }
		.onDisappear {
			// Clean up any running task when view disappears
			copyTask?.cancel()
		}
	}

	@ViewBuilder private var redoMenu: some View {
		if transcript.failure == nil {
			Menu("Rewrite Again As") {
				ForEach([RewriteMode.clean, .prompt], id: \.self) { mode in
					Button(mode.displayName) { send(.rewriteAgain(transcript.id, mode)) }
				}
			}
			.disabled(isWorking)
		}
		if transcript.audioRemoved != true {
			Menu("Transcribe Again With") {
				ForEach(engines) { engine in
					Button(engine.displayName) { send(.transcribeAgain(transcript.id, engine: engine.name)) }
				}
			}
			.disabled(isWorking || engines.isEmpty)
		}
		if let rawText = transcript.rawText {
			Button("Copy Original") { send(.copyToClipboard(rawText)) }
		}
	}

	@State private var showCopied = false
	@State private var copyTask: Task<Void, Error>?

	private func showCopyAnimation() {
		copyTask?.cancel()

		copyTask = Task {
			withAnimation {
				showCopied = true
			}

			try await Task.sleep(for: .seconds(1.5))

			withAnimation {
				showCopied = false
			}
		}
	}
}

#Preview {
	TranscriptView(
		transcript: Transcript(timestamp: Date(), text: "Hello, world!", audioPath: URL(fileURLWithPath: "/Users/langton/Downloads/test.m4a"), duration: 1.0),
		isPlaying: false,
		onPlay: {},
		onCopy: {},
		onDelete: {}
	)
}

struct HistoryView: View {
	@ObserveInjection var inject
	let store: StoreOf<HistoryFeature>
	@State private var showingDeleteConfirmation = false
	@Shared(.hexSettings) var hexSettings: HexSettings

	var body: some View {
      Group {
        if !hexSettings.saveTranscriptionHistory {
          ContentUnavailableView {
            Label("History Disabled", systemImage: "clock.arrow.circlepath")
          } description: {
            Text("Transcription history is currently disabled.")
          } actions: {
            Button("Enable in Settings") {
              store.send(.navigateToSettings)
            }
          }
        } else if store.transcriptionHistory.history.isEmpty {
          ContentUnavailableView {
            Label("No Transcriptions", systemImage: "text.bubble")
          } description: {
            Text("Your transcription history will appear here.")
          }
        } else {
          ScrollView {
            LazyVStack(spacing: 12) {
              ForEach(store.transcriptionHistory.history) { transcript in
                TranscriptView(
                  transcript: transcript,
                  isPlaying: store.playingTranscriptID == transcript.id,
                  playingWords: store.playingTranscriptID == transcript.id ? store.playingWords : nil,
                  playbackTime: store.playingTranscriptID == transcript.id ? store.playbackTime : 0,
                  isPreparingPlayback: store.playingTranscriptID == transcript.id && store.audioPlayerController == nil,
                  isWorking: store.working.contains(transcript.id),
                  alternate: store.alternates[transcript.id],
                  redoError: store.redoErrors[transcript.id],
                  engines: store.engines,
                  onPlay: { store.send(.playTranscript(transcript.id)) },
                  onCopy: { store.send(.copyToClipboard(transcript.text)) },
                  onDelete: { store.send(.deleteTranscript(transcript.id)) },
                  send: { store.send($0) }
                )
              }
            }
            .padding()
          }
          .toolbar {
            Button(role: .destructive, action: { showingDeleteConfirmation = true }) {
              Label("Delete All", systemImage: "trash")
            }
          }
          .alert("Delete All Transcripts", isPresented: $showingDeleteConfirmation) {
            Button("Delete All", role: .destructive) {
              store.send(.confirmDeleteAll)
            }
            Button("Cancel", role: .cancel) {}
          } message: {
            Text("Are you sure you want to delete all transcripts? This action cannot be undone.")
          }
        }
      }
      .task { await store.send(.task).finish() }
      .enableInjection()
	}
}

private enum RetryFailure: LocalizedError {
	case nothingHeard

	var errorDescription: String? {
		switch self {
		case .nothingHeard: "No speech was recognized in the recording."
		}
	}
}

/// A downloaded speech model History can transcribe with again.
struct HistoryEngine: Equatable, Identifiable, Sendable {
	var name: String
	var displayName: String
	var id: String { name }
}

/// What another engine heard in an entry's recording.
struct AlternateTranscript: Equatable, Sendable {
	var engine: String
	var text: String
}
