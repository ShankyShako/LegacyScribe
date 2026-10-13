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
		@Shared(.hexSettings) var hexSettings: HexSettings

		var selected: NotesSessionSummary? {
			sessions.first { $0.id == selectedID }
		}

		/// A transcript can be edited once it's complete and no notes are being written from it.
		var canEditTranscript: Bool {
			guard let session = selected?.session else { return false }
			return session.stage == .done || (session.stage == .noting && session.notesError != nil)
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
				state.transcriptDraft = content.transcript
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
