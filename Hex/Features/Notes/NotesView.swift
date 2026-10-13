import AppKit
import ComposableArchitecture
import HexCore
import Inject
import SwiftUI
import UniformTypeIdentifiers

struct NotesView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<NotesFeature>

	var body: some View {
		HSplitView {
			sessionList
				.frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
			Group {
				if let summary = store.selected {
					NotesSessionDetail(store: store, summary: summary)
				} else {
					NotesIntroView(store: store)
				}
			}
			.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
		}
		.task { await store.send(.task).finish() }
		.confirmationDialog(
			"Delete this notes session?",
			isPresented: Binding(
				get: { store.confirmingDeleteID != nil },
				set: { if !$0 { store.confirmingDeleteID = nil } }
			)
		) {
			Button("Delete", role: .destructive) { store.send(.confirmDelete) }
		} message: {
			Text("Its notes and transcript are deleted. A copy in your export folder stays.")
		}
		.enableInjection()
	}

	private var sessionList: some View {
		List(selection: Binding(get: { store.selectedID }, set: { store.send(.select($0)) })) {
			if store.sessions.isEmpty {
				Text("No notes sessions yet.")
					.foregroundStyle(.secondary)
			}
			ForEach(store.sessions) { summary in
				NotesSessionRow(summary: summary)
					.tag(summary.id)
					.contextMenu {
						Button("Reveal in Finder") { store.send(.reveal(summary.id)) }
						Button("Delete…", role: .destructive) { store.send(.requestDelete(summary.id)) }
					}
			}
		}
		.safeAreaInset(edge: .bottom) {
			HStack {
				Button {
					store.send(.select(nil))
				} label: {
					Label("How notes work", systemImage: "info.circle")
				}
				.buttonStyle(.borderless)
				Spacer()
			}
			.padding(8)
		}
	}
}

private struct NotesSessionRow: View {
	var summary: NotesSessionSummary

	var body: some View {
		VStack(alignment: .leading, spacing: 3) {
			Text(summary.session.startedAt.formatted(date: .abbreviated, time: .shortened))
				.font(.body.weight(.medium))
			HStack(spacing: 4) {
				if summary.session.notesError != nil {
					Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
				}
				Text(NotesStatusText.line(summary))
			}
			.font(.caption)
			.foregroundStyle(.secondary)
			if let progress = NotesStatusText.progress(summary) {
				ProgressView(value: progress).controlSize(.small)
			}
		}
		.padding(.vertical, 2)
	}
}

enum NotesStatusText {
	static func duration(_ seconds: TimeInterval) -> String {
		Duration.seconds(max(0, seconds)).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
	}

	static func line(_ summary: NotesSessionSummary) -> String {
		let length = duration(summary.approximateSeconds)
		switch summary.session.stage {
		case .recording:
			return "Recording · \(summary.words) words so far"
		case .transcribing:
			return "\(length) · transcribing, \(summary.pendingChunks) left"
		case .noting:
			if summary.session.notesError != nil { return "\(length) · notes failed" }
			if let progress = summary.progress, progress.partsTotal > 1 {
				return "\(length) · writing notes, part \(min(progress.partsDone + 1, progress.partsTotal)) of \(progress.partsTotal)"
			}
			return "\(length) · writing notes"
		case .done:
			return "\(length) · \(summary.words) words"
		}
	}

	/// Fraction done while transcribing or writing notes; nil otherwise.
	static func progress(_ summary: NotesSessionSummary) -> Double? {
		switch summary.session.stage {
		case .transcribing:
			let total = summary.transcribedChunks + summary.pendingChunks
			return total > 0 ? Double(summary.transcribedChunks) / Double(total) : nil
		case .noting where summary.session.notesError == nil:
			guard let progress = summary.progress, progress.partsTotal > 0 else { return nil }
			return Double(progress.partsDone) / Double(progress.partsTotal + 1)
		default:
			return nil
		}
	}
}

private struct NotesSessionDetail: View {
	@Bindable var store: StoreOf<NotesFeature>
	var summary: NotesSessionSummary

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
				.padding(16)
			Divider()
			if store.showing == .transcript, let draft = store.transcriptDraft {
				TextEditor(text: Binding(get: { draft }, set: { store.transcriptDraft = $0 }))
					.font(.body)
					.scrollContentBackground(.hidden)
					.padding(12)
			} else {
				content
			}
		}
	}

	private var content: some View {
		ScrollView {
			Group {
				if let content = store.content {
					switch store.showing {
					case .notes:
						if let notes = content.notes {
							NotesMarkdownView(text: notes)
						} else {
							Text(placeholder).foregroundStyle(.secondary)
						}
					case .transcript:
						Text(content.transcript.isEmpty ? "Nothing transcribed yet." : content.transcript)
							.textSelection(.enabled)
							.foregroundStyle(content.transcript.isEmpty ? .secondary : .primary)
					}
				} else {
					ProgressView().controlSize(.small)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(16)
		}
	}

	private var placeholder: String {
		switch summary.session.stage {
		case .recording: "Notes are written once the session stops."
		case .transcribing: "Notes are written once the transcript is complete."
		case .noting: summary.session.notesError == nil ? "Writing notes…" : "The notes couldn't be written."
		case .done: "No notes."
		}
	}

	private var header: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(alignment: .firstTextBaseline) {
				VStack(alignment: .leading, spacing: 2) {
					Text(summary.session.startedAt.formatted(date: .complete, time: .shortened))
						.font(.headline)
					Text(NotesStatusText.line(summary) + gapsText)
						.font(.callout)
						.foregroundStyle(.secondary)
				}
				Spacer()
				actions
			}
			if let error = summary.session.notesError {
				Label(error, systemImage: "exclamationmark.triangle.fill")
					.font(.callout)
					.foregroundStyle(.orange)
					.textSelection(.enabled)
			}
			if store.transcriptDraft != nil {
				Label {
					Text(store.transcriptError ?? "One paragraph per stretch of about 25 seconds. Fix words, delete what wasn't said, then save: the notes are written again from your version. The transcript as first recorded is kept in the session folder.")
				} icon: {
					Image(systemName: store.transcriptError == nil ? "pencil" : "exclamationmark.triangle.fill")
				}
				.font(.callout)
				.foregroundStyle(store.transcriptError == nil ? Color.secondary : Color.orange)
			}
			Picker("Show", selection: $store.showing) {
				ForEach(NotesFeature.Showing.allCases, id: \.self) { Text($0.rawValue).tag($0) }
			}
			.pickerStyle(.segmented)
			.labelsHidden()
			.frame(maxWidth: 260)
			.disabled(store.transcriptDraft != nil)
		}
	}

	private var gapsText: String {
		switch summary.gaps {
		case 0: ""
		case 1: " · 1 gap"
		default: " · \(summary.gaps) gaps"
		}
	}

	@ViewBuilder
	private var actions: some View {
		if store.transcriptDraft != nil {
			HStack(spacing: 8) {
				Button("Cancel") { store.send(.cancelTranscriptEdit) }
					.keyboardShortcut(.cancelAction)
				Button("Save and rewrite notes") { store.send(.saveTranscript) }
					.buttonStyle(.borderedProminent)
			}
		} else {
			viewingActions
		}
	}

	private var viewingActions: some View {
		HStack(spacing: 8) {
			if store.showing == .transcript, store.canEditTranscript {
				Button {
					store.send(.editTranscript)
				} label: {
					Label("Edit", systemImage: "pencil")
				}
				.disabled(store.content == nil)
			}
			if summary.session.notesError != nil {
				Button("Retry") { store.send(.retry(summary.id)) }
					.buttonStyle(.borderedProminent)
			}
			Button {
				store.send(.copyShown)
			} label: {
				Label("Copy", systemImage: "doc.on.doc")
			}
			.disabled(store.content == nil)
			Menu {
				Button("Export Markdown…") { export() }
					.disabled(store.content == nil)
				Button("Reveal in Finder") { store.send(.reveal(summary.id)) }
				if summary.session.stage == .done {
					Button("Write the notes again") { store.send(.retry(summary.id)) }
				}
				Divider()
				Button("Delete…", role: .destructive) { store.send(.requestDelete(summary.id)) }
					.disabled(summary.session.stage == .recording)
			} label: {
				Image(systemName: "ellipsis.circle")
			}
			.menuStyle(.borderlessButton)
			.fixedSize()
		}
	}

	private func export() {
		let panel = NSSavePanel()
		panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
		panel.nameFieldStringValue = "Notes \(summary.id).md"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		store.send(.export(to: url))
	}
}

/// Shown when no session is selected: how Notes mode works, and its settings.
private struct NotesIntroView: View {
	@Bindable var store: StoreOf<NotesFeature>
	@State private var ollamaURL = ""
	@State private var model = ""

	var body: some View {
		Form {
			Section {
				Label {
					Text("Pick Notes with ⌃⌥4 or the ⌃⌥ switcher, then tap the talk key to start and tap it again to stop (Esc stops too). Speak hands-free for up to 2 hours. Cohere Transcribe writes the transcript while you talk; when you stop, an AI model on this Mac turns it into notes. Nothing leaves this Mac, and no audio is kept.")
						.settingsCaption()
				} icon: {
					Image(systemName: RewriteMode.notes.systemImage)
				}
			} header: {
				Text("Notes")
			}

			Section {
				Label {
					Picker("Notes are written by", selection: Binding(
						get: { store.hexSettings.notesWriter },
						set: { store.send(.setWriter($0)) }
					)) {
						Text("A model on this Mac").tag(NotesWriter.onDevice)
						Text("Ollama").tag(NotesWriter.ollama)
					}
				} icon: {
					Image(systemName: "cpu")
				}
				if store.hexSettings.notesWriter == .onDevice {
					Label {
						Picker("Model", selection: Binding(
							get: { store.hexSettings.notesLocalModel },
							set: { store.send(.setLocalModel($0)) }
						)) {
							ForEach(LocalLLMModel.allCases) { model in
								Text(LocalLLM.isDownloaded(model) ? model.displayName : "\(model.displayName), not downloaded")
									.tag(model.repository)
							}
						}
						Text("Download models in AI Rewrite. The Balanced or Large model writes the best notes.")
							.settingsCaption()
					} icon: {
						Image(systemName: "arrow.down.circle")
					}
				} else {
					Label {
						TextField("Ollama URL", text: $ollamaURL, prompt: Text("http://localhost:11434"))
							.onSubmit { store.send(.setOllamaURL(ollamaURL.trimmingCharacters(in: .whitespaces))) }
					} icon: {
						Image(systemName: "server.rack")
					}
					Label {
						TextField("Ollama model", text: $model, prompt: Text("qwen3:8b"))
							.onSubmit { store.send(.setModel(model.trimmingCharacters(in: .whitespaces))) }
						Text("Any model you've pulled in Ollama. Notes use Ollama's own API with a 16K context.")
							.settingsCaption()
					} icon: {
						Image(systemName: "shippingbox")
					}
				}
				Label {
					Toggle("Voice isolation", isOn: Binding(
						get: { store.hexSettings.voiceIsolationInNotes },
						set: { store.send(.setVoiceIsolation($0)) }
					))
					Text("Keeps only the voice nearest the microphone. Leave it off to capture everyone in a meeting.")
						.settingsCaption()
				} icon: {
					Image(systemName: "person.wave.2")
				}
				Label {
					HStack {
						Text(store.hexSettings.notesExportFolder.map { URL(filePath: $0).lastPathComponent } ?? "In the app only")
							.foregroundStyle(store.hexSettings.notesExportFolder == nil ? .secondary : .primary)
						Spacer()
						if store.hexSettings.notesExportFolder != nil {
							Button("Stop exporting") { store.send(.setExportFolder(nil)) }
						}
						Button("Choose…") { chooseFolder() }
					}
					Text("Each session's notes are also saved there as Markdown, an Obsidian vault for example.")
						.settingsCaption()
				} icon: {
					Image(systemName: "folder")
				}
			} header: {
				Text("Settings")
			}
		}
		.formStyle(.grouped)
		.onAppear {
			ollamaURL = store.hexSettings.notesOllamaURL
			model = store.hexSettings.notesModel
		}
		.onDisappear {
			saveFields()
		}
	}

	private func saveFields() {
		let url = ollamaURL.trimmingCharacters(in: .whitespaces)
		let name = model.trimmingCharacters(in: .whitespaces)
		if !url.isEmpty, url != store.hexSettings.notesOllamaURL { store.send(.setOllamaURL(url)) }
		if !name.isEmpty, name != store.hexSettings.notesModel { store.send(.setModel(name)) }
	}

	private func chooseFolder() {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.canCreateDirectories = true
		panel.prompt = "Export here"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		store.send(.setExportFolder(url))
	}
}

/// Just enough Markdown for notes: headings, bullets (nested by indent) and inline styles.
struct NotesMarkdownView: View {
	var text: String

	var body: some View {
		VStack(alignment: .leading, spacing: 5) {
			ForEach(Array(text.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
				row(line)
			}
		}
		.textSelection(.enabled)
	}

	@ViewBuilder
	private func row(_ line: String) -> some View {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		let indent = CGFloat(line.prefix { $0 == " " || $0 == "\t" }.count / 2) * 14
		if trimmed.isEmpty {
			EmptyView()
		} else if trimmed.hasPrefix("#") {
			Text(inline(String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
				.font(trimmed.hasPrefix("## ") || trimmed.hasPrefix("### ") ? .headline : .title3.bold())
				.padding(.top, 8)
		} else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
			HStack(alignment: .firstTextBaseline, spacing: 6) {
				Text("•").foregroundStyle(.secondary)
				Text(inline(String(trimmed.dropFirst(2))))
			}
			.padding(.leading, indent)
		} else {
			Text(inline(trimmed))
				.padding(.leading, indent)
		}
	}

	private func inline(_ text: String) -> AttributedString {
		(try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
			?? AttributedString(text)
	}
}
