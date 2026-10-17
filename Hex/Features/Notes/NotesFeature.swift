import AppKit
import ComposableArchitecture
import Foundation
import HexCore

/// The Notes tab: notes sessions with their notes and transcripts, and the notes settings.
@Reducer
struct NotesFeature {
	@ObservableState
	struct State: Equatable {
		var sessions: [NotesSessionSummary] = []
		var selectedID: String?
		var content: NotesContent?
		var showing: Showing = .notes
		var confirmingDeleteID: String?
		/// The transcript being edited (one paragraph per chunk); nil when not editing.
		var transcriptDraft: String?
		var transcriptError: String?
		/// The user's voiceprint ("You" in labelled transcripts); nil until learned.
		var voiceprint: Voiceprint?
		/// Fraction of recordings done while the voiceprint is being learned; nil otherwise.
		var voiceLearning: Double?
		var voiceError: String?
		var confirmingForgetVoice = false
		/// Other people's voiceprints, named in transcripts.
		var rememberedVoices: [Voiceprint] = []
		/// The remembered person waiting for the Forget confirmation.
		var confirmingForgetPersonID: String?
		var speakerNameError: String?
		/// Trim mode (DESIGN.md "Notes trimming"): the transcript's sentences can be selected and left out.
		var trimming = false
		var trimSelection: TrimSelection?
		var trimError: String?
		@Shared(.hexSettings) var hexSettings: HexSettings
		@Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory

		mutating func resetTrim() {
			trimming = false
			trimSelection = nil
			trimError = nil
		}

		var selected: NotesSessionSummary? {
			sessions.first { $0.id == selectedID }
		}

		/// A transcript can be edited once it's complete and no notes are being written from it.
		var canEditTranscript: Bool {
			guard let session = selected?.session else { return false }
			return session.stage == .done || (session.stage == .noting && session.notesError != nil)
		}
	}

	/// The sentences from `start` to `end`, both inclusive and in order. `anchor` is where the selection was
	/// begun (`a`): a shift-click extends from it, whichever end it is.
	struct TrimSelection: Equatable {
		var start: NotesTrimPoint
		var end: NotesTrimPoint
		var anchor: NotesTrimPoint

		init(_ a: NotesTrimPoint, _ b: NotesTrimPoint) {
			start = min(a, b)
			end = max(a, b)
			anchor = a
		}
	}

	enum Showing: String, CaseIterable, Equatable {
		case notes = "Notes"
		case transcript = "Transcript"
	}

	enum Action: BindableAction {
		case binding(BindingAction<State>)
		case task
		case reload
		case loaded([NotesSessionSummary])
		case select(String?)
		case contentLoaded(id: String, NotesContent)
		case retry(String)
		case requestDelete(String)
		case confirmDelete
		case copyShown
		case editTranscript
		case cancelTranscriptEdit
		case saveTranscript
		case transcriptSaved
		case transcriptSaveFailed(String)
		case export(to: URL)
		case reveal(String)
		case setWriter(NotesWriter)
		case setLocalModel(String)
		case setVoiceIsolation(Bool)
		case setOllamaURL(String)
		case setModel(String)
		case setExportFolder(URL?)
		case setSpeakerLabels(Bool)
		case voiceprintLoaded(Voiceprint?)
		case learnVoice
		case voiceLearningProgress(Double)
		case voiceLearned(Voiceprint)
		case voiceLearningFailed(String)
		case requestForgetVoice
		case confirmForgetVoice
		case nameSpeaker(speaker: Int, name: String, remember: Bool)
		case speakerNamingFailed(String)
		case rememberedVoicesLoaded([Voiceprint])
		case requestForgetPerson(String)
		case confirmForgetPerson
		case beginTrim
		case endTrim
		case selectSentences(from: NotesTrimPoint, to: NotesTrimPoint)
		/// Shift-click: the selection runs from where it began to this sentence.
		case extendSelection(to: NotesTrimPoint)
		case leaveOutSelection
		case bringBack(Int)
		case trimFailed(String)
	}

	@Dependency(\.notes) var notes
	@Dependency(\.pasteboard) var pasteboard

	var body: some ReducerOf<Self> {
		BindingReducer()
		Reduce { state, action in
			switch action {
			case .binding:
				return .none

			case .task:
				return .merge(
					.send(.reload),
					.run { send in await send(.voiceprintLoaded(await notes.voiceprint())) },
					.run { send in await send(.rememberedVoicesLoaded(await notes.rememberedVoices())) },
					.run { send in
						for await event in notes.events() {
							if case .changed = event { await send(.reload) }
						}
					}
				)

			case .reload:
				let id = state.selectedID
				return .run { send in
					await send(.loaded(await notes.list()))
					if let id {
						await send(.contentLoaded(id: id, await notes.content(id)))
					}
				}

			case let .loaded(sessions):
				state.sessions = sessions
				if let id = state.selectedID, !sessions.contains(where: { $0.id == id }) {
					state.selectedID = nil
					state.content = nil
				}
				return .none

			case let .select(id):
				guard id != state.selectedID else { return .none }
				state.selectedID = id
				state.content = nil
				state.transcriptDraft = nil
				state.transcriptError = nil
				state.speakerNameError = nil
				state.resetTrim()
				guard let id else { return .none }
				return .run { send in
					await send(.contentLoaded(id: id, await notes.content(id)))
				}

			case let .contentLoaded(id, content):
				guard id == state.selectedID else { return .none }
				state.content = content
				return .none

			case let .retry(id):
				return .run { _ in await notes.retryNotes(id) }

			case let .requestDelete(id):
				state.confirmingDeleteID = id
				return .none

			case .confirmDelete:
				guard let id = state.confirmingDeleteID else { return .none }
				state.confirmingDeleteID = nil
				return .run { send in
					do {
						try await notes.delete(id)
					} catch {
						HexLog.notes.error("Deleting notes session \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
					}
					await send(.reload)
				}

			case .copyShown:
				guard let content = state.content else { return .none }
				let text = state.showing == .notes ? (content.notes ?? "") : content.transcript
				return .run { _ in await pasteboard.copy(text) }

			case .editTranscript:
				guard state.canEditTranscript, let content = state.content else { return .none }
				state.showing = .transcript
				// The whole transcript, left-out stretches included: saving re-anchors the trims to the edit.
				state.resetTrim()
				state.transcriptDraft = content.fullTranscript
				state.transcriptError = nil
				return .none

			case .cancelTranscriptEdit:
				state.transcriptDraft = nil
				state.transcriptError = nil
				return .none

			case .saveTranscript:
				guard let id = state.selectedID, let text = state.transcriptDraft else { return .none }
				return .run { send in
					do {
						try await notes.saveTranscript(id, text)
						await send(.transcriptSaved)
					} catch {
						await send(.transcriptSaveFailed(error.localizedDescription))
					}
				}

			case .transcriptSaved:
				state.transcriptDraft = nil
				state.transcriptError = nil
				state.showing = .notes
				return .send(.reload)

			case let .transcriptSaveFailed(message):
				state.transcriptError = message
				return .none

			case let .export(url):
				guard let summary = state.selected, let content = state.content else { return .none }
				let markdown = Self.markdown(summary.session, content: content)
				return .run { _ in
					do {
						try markdown.write(to: url, atomically: true, encoding: .utf8)
					} catch {
						HexLog.notes.error("Notes export failed: \(error.localizedDescription, privacy: .public)")
					}
				}

			case let .reveal(id):
				let url = URL.notesFolderURL.appending(component: id, directoryHint: .isDirectory)
				return .run { _ in
					await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
				}

			case let .setWriter(writer):
				state.$hexSettings.withLock { $0.notesWriter = writer }
				return .none

			case let .setLocalModel(repository):
				state.$hexSettings.withLock { $0.notesLocalModel = repository }
				return .none

			case let .setVoiceIsolation(enabled):
				state.$hexSettings.withLock { $0.voiceIsolationInNotes = enabled }
				return .none

			case let .setOllamaURL(url):
				state.$hexSettings.withLock { $0.notesOllamaURL = url }
				return .none

			case let .setModel(model):
				state.$hexSettings.withLock { $0.notesModel = model }
				return .none

			case let .setExportFolder(url):
				state.$hexSettings.withLock { $0.notesExportFolder = url?.path(percentEncoded: false) }
				return .none

			case let .setSpeakerLabels(enabled):
				state.$hexSettings.withLock { $0.notesSpeakerLabels = enabled }
				return .none

			case let .voiceprintLoaded(voiceprint):
				state.voiceprint = voiceprint
				return .none

			case .learnVoice:
				guard state.voiceLearning == nil else { return .none }
				state.voiceLearning = 0
				state.voiceError = nil
				let history = state.transcriptionHistory.history
				return .run { send in
					let (progress, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
					let forward = Task {
						for await fraction in progress { await send(.voiceLearningProgress(fraction)) }
					}
					do {
						let voiceprint = try await notes.enrolVoiceprint(history) { continuation.yield($0) }
						continuation.finish()
						await forward.value
						await send(.voiceLearned(voiceprint))
					} catch {
						continuation.finish()
						await forward.value
						HexLog.notes.error("Learning the voiceprint failed: \(error.localizedDescription, privacy: .public)")
						await send(.voiceLearningFailed(error.localizedDescription))
					}
				}

			case let .voiceLearningProgress(fraction):
				guard state.voiceLearning != nil else { return .none }
				state.voiceLearning = fraction
				return .none

			case let .voiceLearned(voiceprint):
				state.voiceLearning = nil
				state.voiceprint = voiceprint
				return .none

			case let .voiceLearningFailed(message):
				state.voiceLearning = nil
				state.voiceError = message
				return .none

			case .requestForgetVoice:
				state.confirmingForgetVoice = true
				return .none

			case .confirmForgetVoice:
				state.confirmingForgetVoice = false
				state.voiceError = nil
				return .run { send in
					do {
						try await notes.deleteVoiceprint()
					} catch {
						HexLog.notes.error("Forgetting the voiceprint failed: \(error.localizedDescription, privacy: .public)")
					}
					await send(.voiceprintLoaded(await notes.voiceprint()))
				}

			case let .nameSpeaker(speaker, name, remember):
				guard let id = state.selectedID else { return .none }
				state.speakerNameError = nil
				return .run { send in
					do {
						try await notes.nameSpeaker(id, speaker, name, remember)
					} catch {
						HexLog.notes.error("Naming a speaker failed: \(error.localizedDescription, privacy: .public)")
						await send(.speakerNamingFailed(error.localizedDescription))
					}
					await send(.rememberedVoicesLoaded(await notes.rememberedVoices()))
					await send(.reload)
				}

			case let .speakerNamingFailed(message):
				state.speakerNameError = message
				return .none

			case let .rememberedVoicesLoaded(voices):
				state.rememberedVoices = voices
				return .none

			case let .requestForgetPerson(voiceprintID):
				state.confirmingForgetPersonID = voiceprintID
				return .none

			case .beginTrim:
				guard state.canEditTranscript, state.content != nil, state.transcriptDraft == nil else { return .none }
				state.showing = .transcript
				state.trimming = true
				state.trimSelection = nil
				state.trimError = nil
				return .none

			case .endTrim:
				state.resetTrim()
				return .none

			case let .selectSentences(from, to):
				guard state.trimming else { return .none }
				state.trimSelection = TrimSelection(from, to)
				return .none

			case let .extendSelection(to):
				guard state.trimming else { return .none }
				state.trimSelection = TrimSelection(state.trimSelection?.anchor ?? to, to)
				return .none

			case .leaveOutSelection:
				guard state.trimming, let selection = state.trimSelection, let id = state.selectedID else { return .none }
				state.trimSelection = nil
				state.trimError = nil
				return .run { send in
					do {
						try await notes.leaveOut(id, selection.start, selection.end)
						await send(.reload)
					} catch {
						await send(.trimFailed(error.localizedDescription))
					}
				}

			case let .bringBack(index):
				guard let id = state.selectedID else { return .none }
				state.trimError = nil
				return .run { send in
					do {
						try await notes.bringBack(id, index)
						await send(.reload)
					} catch {
						await send(.trimFailed(error.localizedDescription))
					}
				}

			case let .trimFailed(message):
				state.trimError = message
				return .none

			case .confirmForgetPerson:
				guard let voiceprintID = state.confirmingForgetPersonID else { return .none }
				state.confirmingForgetPersonID = nil
				return .run { send in
					do {
						try await notes.forgetRememberedVoice(voiceprintID)
					} catch {
						HexLog.notes.error("Forgetting a remembered voice failed: \(error.localizedDescription, privacy: .public)")
					}
					await send(.rememberedVoicesLoaded(await notes.rememberedVoices()))
				}
			}
		}
	}

	/// One Markdown file with the notes, then the transcript.
	static func markdown(_ session: NotesSession, content: NotesContent) -> String {
		let title = "# Notes, \(session.startedAt.formatted(date: .long, time: .shortened))"
		let notes = content.notes ?? "_The notes aren't written yet._"
		return "\(title)\n\n\(notes)\n\n## Transcript\n\n\(content.transcript)\n"
	}
}
