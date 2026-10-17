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
		VStack(spacing: 0) {
			settingsRow
			Divider()
			sessions
		}
	}

	/// Fixed above the sessions so it never covers one; opens the page with the settings and how notes work.
	private var settingsRow: some View {
		let active = store.selectedID == nil
		return Button {
			store.send(.select(nil))
		} label: {
			Label("Notes settings", systemImage: "gearshape")
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal, 8)
				.padding(.vertical, 5)
				.background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor.opacity(0.15) : .clear))
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help("The notes model, export folder, speakers and how notes work")
		.padding(8)
	}

	private var sessions: some View {
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

struct NotesSessionDetail: View {
	@Bindable var store: StoreOf<NotesFeature>
	var summary: NotesSessionSummary
	@State private var scrollPosition = ScrollPosition()
	/// The transcript's scroll offset and its limit, for scrolling while a selection is dragged. A reference,
	/// so scrolling doesn't redraw the session.
	@State private var scrollRange = ScrollRange()

	private final class ScrollRange {
		var offset: CGFloat = 0
		var limit: CGFloat = 0
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
				.padding(16)
			Divider()
			if store.showing == .transcript, store.transcriptDraft != nil {
				// Read the store in `get`: a value captured at render time is stale right after a keystroke, and
				// the editor then resets its text, which throws the cursor and scroll to the end.
				TextEditor(text: Binding(get: { store.transcriptDraft ?? "" }, set: { store.transcriptDraft = $0 }))
					.font(.body)
					.scrollContentBackground(.hidden)
					.padding(12)
			} else {
				content
			}
			if store.trimming, store.showing == .transcript {
				trimBar
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
						if content.sentences.isEmpty {
							Text("Nothing transcribed yet.")
								.foregroundStyle(.secondary)
						} else {
							if let error = store.speakerNameError {
								Label(error, systemImage: "exclamationmark.triangle.fill")
									.font(.callout)
									.foregroundStyle(.orange)
									.padding(.bottom, 8)
							}
							NotesSpeakerTranscript(
								items: content.sentences,
								trims: content.trims,
								showsChips: content.speakerCount > 1 && !content.speakerParagraphs.isEmpty,
								trimming: store.trimming,
								selection: store.trimSelection,
								onName: { speaker, name, remember in
									store.send(.nameSpeaker(speaker: speaker, name: name, remember: remember))
								},
								onBringBack: { store.send(.bringBack($0)) },
								onSelect: { store.send(.selectSentences(from: $0, to: $1)) },
								onExtend: { store.send(.extendSelection(to: $0)) },
								autoscroll: scroll(by:)
							)
						}
					}
				} else {
					ProgressView().controlSize(.small)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(16)
		}
		.scrollPosition($scrollPosition)
		.onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
			scrollRange.offset = geometry.contentOffset.y
			scrollRange.limit = max(geometry.contentSize.height - geometry.containerSize.height, 0)
		}
	}

	/// Scrolls the transcript by up to `delta` points; returns how far it moved.
	private func scroll(by delta: CGFloat) -> CGFloat {
		let from = scrollRange.offset
		let to = min(max(from + delta, 0), scrollRange.limit)
		guard to != from else { return 0 }
		scrollPosition.scrollTo(y: to)
		scrollRange.offset = to
		return to - from
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
					Text(NotesStatusText.line(summary) + gapsText + speakersText)
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
			if summary.notesStale {
				staleBanner
			}
			if store.trimming, store.showing == .transcript {
				Text(store.trimError ?? "Drag across the transcript or the strip above it, or click a sentence and shift-click another, to select what to leave out.")
					.font(.callout)
					.foregroundStyle(store.trimError == nil ? Color.secondary : Color.orange)
			} else if let error = store.trimError {
				Label(error, systemImage: "exclamationmark.triangle.fill")
					.font(.callout)
					.foregroundStyle(.orange)
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
			.disabled(store.transcriptDraft != nil || store.trimming)
			if store.trimming, store.showing == .transcript, let content = store.content {
				NotesTrimStrip(
					sentences: content.sentences,
					sessionSeconds: content.sessionSeconds,
					selection: store.trimSelection,
					onSelect: { store.send(.selectSentences(from: $0, to: $1)) }
				)
			}
		}
	}

	/// The notes were written before the latest change to what is left out.
	private var staleBanner: some View {
		let count = store.content?.trims.count ?? 0
		return HStack(spacing: 8) {
			Image(systemName: "scissors").foregroundStyle(.secondary)
			Text(Self.staleText(count))
				.font(.callout)
				.foregroundStyle(.secondary)
			Spacer()
			Button("Write notes again") { store.send(.retry(summary.id)) }
				.buttonStyle(.borderedProminent)
				.controlSize(.small)
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 6)
		.background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
	}

	static func staleText(_ count: Int) -> String {
		switch count {
		case 0: "You brought back left-out stretches. The notes still leave them out."
		case 1: "1 stretch left out. The notes still include it."
		default: "\(count) stretches left out. The notes still include them."
		}
	}

	/// What the selection covers: "5 sentences · about 0:40 selected". Left-out sentences don't count.
	private var trimBar: some View {
		let covered = (store.content?.sentences ?? []).filter { item in
			store.trimSelection.map { $0.start <= item.point && item.point <= $0.end } == true && item.trimIndex == nil
		}
		let seconds = covered.reduce(0) { $0 + ($1.end - $1.start) }
		return HStack(spacing: 10) {
			Text(store.trimSelection == nil
				? "Nothing selected"
				: "\(covered.count) sentence\(covered.count == 1 ? "" : "s") · about \(NotesTimeline.clock(seconds)) selected")
				.font(.callout)
				.foregroundStyle(.secondary)
			Spacer()
			Button("Cancel") { store.trimSelection = nil }
				.disabled(store.trimSelection == nil)
			Button {
				store.send(.leaveOutSelection)
			} label: {
				Label("Leave out of notes", systemImage: "eye.slash")
			}
			.buttonStyle(.borderedProminent)
			.disabled(store.trimSelection == nil)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)).shadow(color: .black.opacity(0.18), radius: 6, y: 2))
		.padding(.horizontal, 16)
		.padding(.bottom, 12)
		.padding(.top, 4)
	}

	private var gapsText: String {
		switch summary.gaps {
		case 0: ""
		case 1: " · 1 gap"
		default: " · \(summary.gaps) gaps"
		}
	}

	private var speakersText: String {
		summary.speakerCount > 1 ? " · \(summary.speakerCount) speakers" : ""
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
					store.send(store.trimming ? .endTrim : .beginTrim)
				} label: {
					Label(store.trimming ? "Done" : "Trim", systemImage: store.trimming ? "checkmark" : "scissors")
				}
				.disabled(store.content == nil)
				if !store.trimming {
					Button {
						store.send(.editTranscript)
					} label: {
						Label("Edit", systemImage: "pencil")
					}
					.disabled(store.content == nil)
				}
			}
			if summary.session.notesError != nil {
				Button("Retry") { store.send(.retry(summary.id)) }
					.buttonStyle(.borderedProminent)
			}
			if !store.trimming {
				Button {
					store.send(.copyShown)
				} label: {
					Label("Copy", systemImage: "doc.on.doc")
				}
				.disabled(store.content == nil)
			}
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

			speakersSection
		}
		.formStyle(.grouped)
		.confirmationDialog(
			"Forget your voice?",
			isPresented: Binding(
				get: { store.confirmingForgetVoice },
				set: { if !$0 { store.confirmingForgetVoice = false } }
			)
		) {
			Button("Forget", role: .destructive) { store.send(.confirmForgetVoice) }
		} message: {
			Text("New sessions won't label you as \"You\" until your voice is learned again. Your notes and transcripts are untouched.")
		}
		.confirmationDialog(
			"Forget \(forgettingName)'s voice?",
			isPresented: Binding(
				get: { store.confirmingForgetPersonID != nil },
				set: { if !$0 { store.confirmingForgetPersonID = nil } }
			)
		) {
			Button("Forget", role: .destructive) { store.send(.confirmForgetPerson) }
		} message: {
			Text("New sessions won't recognise this voice. Transcripts that already name \(forgettingName) keep the name.")
		}
		.onAppear {
			ollamaURL = store.hexSettings.notesOllamaURL
			model = store.hexSettings.notesModel
		}
		.onDisappear {
			saveFields()
		}
	}

	private var speakersSection: some View {
		Section {
			Label {
				Toggle("Label who is speaking", isOn: Binding(
					get: { store.hexSettings.notesSpeakerLabels },
					set: { store.send(.setSpeakerLabels($0)) }
				))
				Text("Shown only when a session heard more than one voice. Everything stays on this Mac.")
					.settingsCaption()
			} icon: {
				Image(systemName: "person.2")
			}
			Label {
				LabeledContent("Your voice") {
					Text(voiceStatus)
				}
			} icon: {
				Image(systemName: "waveform")
					.foregroundStyle(Color.accentColor)
			}
			Label {
				if let fraction = store.voiceLearning {
					HStack(spacing: 8) {
						ProgressView(value: fraction)
							.controlSize(.small)
						Text("Learning from your dictations…")
							.foregroundStyle(.secondary)
							.fixedSize()
					}
				} else {
					HStack(spacing: 8) {
						Button("Learn from my dictations") { store.send(.learnVoice) }
						Button("Forget") { store.send(.requestForgetVoice) }
							.disabled(store.voiceprint == nil)
					}
				}
				if let error = store.voiceError {
					Text(error)
						.settingsCaption()
						.foregroundStyle(.orange)
				}
			} icon: {
				Image(systemName: "person.crop.circle.badge.checkmark")
			}
			ForEach(store.rememberedVoices, id: \.id) { person in
				Label {
					LabeledContent(person.name ?? "Unnamed voice") {
						Button("Forget") { store.send(.requestForgetPerson(person.id)) }
					}
				} icon: {
					Image(systemName: "person.crop.circle.fill")
						.foregroundStyle(NotesSpeakerTranscript.tint(voiceprintID: person.id))
				}
			}
			Text("Forget removes only the voice sample. Your notes and transcripts are untouched.")
				.settingsCaption()
		} header: {
			Text("Speakers")
		}
	}

	private var forgettingName: String {
		store.rememberedVoices.first { $0.id == store.confirmingForgetPersonID }?.name ?? "this person"
	}

	private var voiceStatus: String {
		guard let voiceprint = store.voiceprint else { return "Not learned yet" }
		let date = voiceprint.enrolledAt.formatted(.dateTime.month(.abbreviated).day())
		return "Learned from \(voiceprint.sourceCount) dictations on \(date)"
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

/// The Transcript tab (option C, DESIGN.md "Notes speaker labels", with "Notes trimming" on top): a tinted
/// chip per speaker in a left column, the text beside it, as sentences so a stretch can be left out.
/// "You" is in the accent colour, everyone else in a muted tint fixed by their number; an overlapping turn
/// gets a note under its text. A solo session has no chip column. A left-out stretch, even one spanning
/// paragraphs, is one dashed row with a "Bring back" link. In trim mode every sentence is selectable.
struct NotesSpeakerTranscript: View {
	/// A row: a run of sentences by one speaker, or a collapsed left-out stretch.
	enum Block: Equatable {
		case text(TextBlock)
		case leftOut(NotesTrimRow)
	}

	struct TextBlock: Equatable {
		var sentences: [NotesSentenceItem]
		/// The chip is drawn on the first segment of a paragraph only.
		var showsChip: Bool
		var paragraph: NotesSpeakerParagraph { sentences[0].paragraph }
	}

	var blocks: [Block]
	var showsChips: Bool
	var trimming = false
	var selection: NotesFeature.TrimSelection?
	/// Save in the naming popover: speaker, name, remember the voice. Nil: chips can't be clicked.
	var onName: ((Int, String, Bool) -> Void)?
	var onBringBack: ((Int) -> Void)?
	var onSelect: ((NotesTrimPoint, NotesTrimPoint) -> Void)?
	var onExtend: ((NotesTrimPoint) -> Void)?
	/// Scrolls the enclosing scroll view by the given points and returns how far it moved, for dragging a
	/// selection past the top or bottom edge. Nil: no scrolling while dragging.
	var autoscroll: ((CGFloat) -> CGFloat)?
	/// Trim mode: the drag in progress and where each sentence is. A reference, so neither a drag step nor a
	/// layout redraws the transcript.
	@State private var drag = TrimDrag()

	private static let space = "notes-transcript"

	/// One row per paragraph, each a single sentence-less block: the labelled transcript as it was drawn
	/// before trimming.
	init(paragraphs: [NotesSpeakerParagraph], onName: ((Int, String, Bool) -> Void)? = nil) {
		blocks = paragraphs.enumerated().map { index, paragraph in
			.text(TextBlock(
				sentences: [NotesSentenceItem(
					point: NotesTrimPoint(chunk: index, turn: 0, sentence: 0), text: paragraph.text, startsParagraph: true,
					paragraph: paragraph, start: 0, end: 0, trimIndex: nil
				)],
				showsChip: true
			))
		}
		showsChips = true
		self.onName = onName
	}

	init(
		items: [NotesSentenceItem], trims: [NotesTrimRow], showsChips: Bool, trimming: Bool = false,
		selection: NotesFeature.TrimSelection? = nil, onName: ((Int, String, Bool) -> Void)? = nil,
		onBringBack: ((Int) -> Void)? = nil, onSelect: ((NotesTrimPoint, NotesTrimPoint) -> Void)? = nil,
		onExtend: ((NotesTrimPoint) -> Void)? = nil, autoscroll: ((CGFloat) -> CGFloat)? = nil
	) {
		blocks = Self.blocks(items, trims: trims)
		self.showsChips = showsChips
		self.trimming = trimming
		self.selection = selection
		self.onName = onName
		self.onBringBack = onBringBack
		self.onSelect = onSelect
		self.onExtend = onExtend
		self.autoscroll = autoscroll
	}

	/// Groups sentences into rows. A paragraph is split where a trim starts or ends; a trim that spans
	/// paragraphs is one row. The chip goes on the first row of a paragraph that shows anything, so a
	/// paragraph that opens with left-out sentences still names its speaker.
	static func blocks(_ items: [NotesSentenceItem], trims: [NotesTrimRow]) -> [Block] {
		var blocks: [Block] = []
		var chipPending = false
		var continuing = false
		for item in items {
			if item.startsParagraph {
				chipPending = true
				continuing = false
			}
			if let index = item.trimIndex {
				if case let .leftOut(row)? = blocks.last, row.index == index { continue }
				if let row = trims.first(where: { $0.index == index }) { blocks.append(.leftOut(row)) }
				continuing = false
				continue
			}
			if continuing, case var .text(block)? = blocks.last {
				block.sentences.append(item)
				blocks[blocks.count - 1] = .text(block)
			} else {
				blocks.append(.text(TextBlock(sentences: [item], showsChip: chipPending)))
				chipPending = false
			}
			continuing = true
		}
		return blocks
	}

	static let chipWidth: CGFloat = 80

	/// Muted tints for speakers other than the user, by speaker number (2 is the first).
	static let tints: [Color] = [
		Color(red: 0.55, green: 0.42, blue: 0.62), // violet
		Color(red: 0.78, green: 0.52, blue: 0.20), // amber
		Color(red: 0.24, green: 0.55, blue: 0.55), // teal
		Color(red: 0.72, green: 0.36, blue: 0.42), // rose
		Color(red: 0.42, green: 0.55, blue: 0.28), // olive
		Color(red: 0.38, green: 0.47, blue: 0.68), // slate blue
		Color(red: 0.58, green: 0.45, blue: 0.35), // brown
	]

	static func tint(_ speaker: Int) -> Color {
		tints[((speaker - 2) % tints.count + tints.count) % tints.count]
	}

	/// A remembered person's tint, the same in every session and in Settings (FNV-1a of the voiceprint ID:
	/// `hashValue` changes between launches).
	static func tint(voiceprintID: String) -> Color {
		var hash: UInt32 = 2_166_136_261
		for byte in voiceprintID.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
		return tints[Int(hash % UInt32(tints.count))]
	}

	static func tint(_ paragraph: NotesSpeakerParagraph, speaker: Int) -> Color {
		paragraph.voiceprintID.map { tint(voiceprintID: $0) } ?? tint(speaker)
	}

	var body: some View {
		// The rows only change when the transcript or its trims do; a new selection redraws the highlight
		// behind them, not the hundreds of sentences.
		let rows = Rows(blocks: blocks, showsChips: showsChips, trimming: trimming, onName: onName, onBringBack: onBringBack)
			.equatable()
		if trimming {
			rows
				.contentShape(Rectangle())
				.onGeometryChange(for: CGRect.self) { $0.bounds(of: .scrollView) ?? .zero } action: { drag.visible = $0 }
				.backgroundPreferenceValue(SentenceBounds.self) { anchors in
					GeometryReader { proxy in
						let frames = anchors.mapValues { proxy[$0] }
						let _ = drag.frames = frames
						highlight(frames)
					}
				}
				.coordinateSpace(name: Self.space)
				.gesture(selectionGesture)
				.onDisappear { drag.stopScrolling() }
		} else {
			rows.textSelection(.enabled)
		}
	}

	/// The selected sentences, tinted in the accent colour.
	private func highlight(_ frames: [NotesTrimPoint: CGRect]) -> some View {
		Canvas { context, _ in
			guard let selection else { return }
			for (point, frame) in frames where selection.start <= point && point <= selection.end {
				context.fill(Path(frame), with: .color(Color.accentColor.opacity(0.15)))
			}
		}
		.allowsHitTesting(false)
	}

	// MARK: Selecting by dragging

	/// Press on a sentence and drag across others to select from one to the other; with shift held, the press
	/// extends the selection from where it was begun instead. The sentence under the pointer is the nearest
	/// one, so the gaps between rows and the space after a short line still count. Dragging past the top or
	/// bottom edge scrolls.
	private var selectionGesture: some Gesture {
		DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
			.onChanged { value in
				if drag.anchor == nil {
					drag.extend = NSEvent.modifierFlags.contains(.shift) && selection != nil
					drag.anchor = drag.extend ? selection?.anchor : drag.nearest(to: value.startLocation)
					drag.last = nil
				}
				drag.pointer = value.location
				select()
				updateScrolling()
			}
			.onEnded { _ in
				drag.stopScrolling()
				drag.anchor = nil
				drag.extend = false
				drag.last = nil
			}
	}

	/// Selects from the anchor to the sentence nearest the pointer, once per change of sentence.
	private func select() {
		guard let anchor = drag.anchor, let current = drag.nearest(to: drag.pointer), drag.last != current else { return }
		drag.last = current
		if drag.extend { onExtend?(current) } else { onSelect?(anchor, current) }
	}

	/// Scrolls while the pointer is within `edge` of the visible area's top or bottom (or past it), faster the
	/// further out it is; the content moving under a still pointer extends the selection.
	private func updateScrolling() {
		guard autoscroll != nil, drag.overshoot != 0 else { return drag.stopScrolling() }
		guard drag.scrolling == nil else { return }
		drag.scrolling = Task { @MainActor in
			while !Task.isCancelled {
				let overshoot = drag.overshoot
				guard overshoot != 0, let autoscroll else { break }
				let moved = autoscroll(max(-30, min(30, overshoot / 2)))
				guard moved != 0 else { break }
				drag.pointer.y += moved
				drag.visible.origin.y += moved
				select()
				try? await Task.sleep(for: .milliseconds(16))
			}
			// A cancelled loop was already let go, and a new one may have taken its place.
			if !Task.isCancelled { drag.scrolling = nil }
		}
	}

	/// Draws the rows; equal rows aren't redrawn (closures don't count).
	private struct Rows: View, Equatable {
		var blocks: [Block]
		var showsChips: Bool
		var trimming: Bool
		var onName: ((Int, String, Bool) -> Void)?
		var onBringBack: ((Int) -> Void)?
		/// The row whose chip has the naming popover open.
		@State private var namingRow: Int?

		static func == (a: Rows, b: Rows) -> Bool {
			a.blocks == b.blocks && a.showsChips == b.showsChips && a.trimming == b.trimming
				&& (a.onName == nil) == (b.onName == nil)
		}

		var body: some View {
			VStack(alignment: .leading, spacing: 12) {
				ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
					switch block {
					case let .text(block): row(block, index: index)
					case let .leftOut(row): leftOutRow(row)
					}
				}
			}
		}

		private var chipColumn: CGFloat { showsChips ? NotesSpeakerTranscript.chipWidth : 0 }

		private func row(_ block: TextBlock, index: Int) -> some View {
			let paragraph = block.paragraph
			return HStack(alignment: trimming ? .top : .firstTextBaseline, spacing: showsChips ? 10 : 0) {
				if showsChips {
					Group {
						if block.showsChip { namingChip(paragraph, index: index) } else { Color.clear.frame(height: 1) }
					}
					.frame(width: chipColumn)
				}
				VStack(alignment: .leading, spacing: 4) {
					if trimming {
						SentenceFlow {
							ForEach(block.sentences, id: \.point) { sentence($0) }
						}
					} else {
						Text(block.sentences.map(\.text).joined(separator: " "))
							.italic(block.sentences.count == 1 && block.sentences[0].text == NotesTranscript.gapMarker)
							.foregroundStyle(block.sentences.count == 1 && block.sentences[0].text == NotesTranscript.gapMarker ? .secondary : .primary)
					}
					if paragraph.overlapping, block.showsChip {
						Label("Overlapping voices", systemImage: "waveform.badge.exclamationmark")
							.labelStyle(OverlapLabelStyle())
							.font(.caption)
							.foregroundStyle(.secondary)
							.padding(.horizontal, 6)
							.padding(.vertical, 1)
							.overlay(Capsule().strokeBorder(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 0.8, dash: [3, 2])))
							.help("Two people were talking at once here, so this text may be less accurate: it can mix both voices.")
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.accessibilityElement(children: .combine)
		}

		/// One sentence in trim mode; its bounds go up for the drag and the selection highlight.
		private func sentence(_ item: NotesSentenceItem) -> some View {
			Text(item.text)
				.italic(item.text == NotesTranscript.gapMarker)
				.foregroundStyle(item.text == NotesTranscript.gapMarker ? .secondary : .primary)
				.padding(.trailing, 4)
				.anchorPreference(key: SentenceBounds.self, value: .bounds) { [item.point: $0] }
		}

		/// A collapsed left-out stretch.
		private func leftOutRow(_ trim: NotesTrimRow) -> some View {
			HStack(spacing: 8) {
				Image(systemName: "eye.slash")
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
				Text("Left out of notes · \(NotesTimeline.clock(max(trim.end - trim.start, 0)))")
					.font(.system(size: 12, weight: .medium))
					.foregroundStyle(.secondary)
					.fixedSize()
				Text("\u{201C}\(trim.gist)\u{201D}")
					.font(.system(size: 12))
					.italic()
					.foregroundStyle(.tertiary)
					.lineLimit(1)
				Spacer(minLength: 8)
				Button("Bring back") { onBringBack?(trim.index) }
					.buttonStyle(.link)
					.font(.system(size: 12))
			}
			.padding(.horizontal, 10)
			.padding(.vertical, 6)
			.background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
			.accessibilityElement(children: .combine)
		}

		/// Everyone but "You" can be named: the chip opens the naming popover, anchored to it.
		@ViewBuilder
		private func namingChip(_ paragraph: NotesSpeakerParagraph, index: Int) -> some View {
			if let onName, let speaker = paragraph.speaker, paragraph.label != nil, !paragraph.isUser || paragraph.markedAsUser {
				Button { namingRow = index } label: {
					NotesSpeakerTranscript.chip(paragraph)
				}
				.buttonStyle(.plain)
				.help(NotesSpeakerTranscript.chipHelp(paragraph))
				.popover(
					isPresented: Binding(get: { namingRow == index }, set: { if !$0 { namingRow = nil } }),
					arrowEdge: .bottom
				) {
					NotesSpeakerNamingForm(paragraph: paragraph) { name, remember in
						namingRow = nil
						onName(speaker, name, remember)
					} onCancel: {
						namingRow = nil
					}
				}
			} else {
				NotesSpeakerTranscript.chip(paragraph)
					.help(paragraph.label == nil || paragraph.isUser ? "" : NotesSpeakerTranscript.chipHelp(paragraph))
			}
		}
	}

	static func chipHelp(_ paragraph: NotesSpeakerParagraph) -> String {
		if paragraph.recognised { return "Recognised by voice" }
		if paragraph.voiceSaved { return "Voice saved: recognised in future sessions" }
		return "Name this speaker"
	}

	/// The speaker's tinted capsule; a remembered voice gets a small waveform mark before the name.
	@ViewBuilder
	static func chip(_ paragraph: NotesSpeakerParagraph) -> some View {
		if let speaker = paragraph.speaker, let label = paragraph.label {
			HStack(spacing: 3) {
				if paragraph.recognised || paragraph.voiceSaved {
					Image(systemName: "waveform")
						.font(.system(size: 8, weight: .semibold))
						.accessibilityLabel("Recognised by voice")
				}
				Text(label)
					.lineLimit(1)
					.minimumScaleFactor(0.8)
			}
			.font(.caption.weight(.semibold))
			.foregroundStyle(paragraph.isUser ? Color.white : tint(paragraph, speaker: speaker))
			.padding(.horizontal, 8)
			.padding(.vertical, 2)
			.frame(maxWidth: .infinity)
			.background(Capsule().fill(paragraph.isUser ? Color.accentColor : tint(paragraph, speaker: speaker).opacity(0.16)))
			.contentShape(Capsule())
		} else {
			Color.clear.frame(height: 1)
		}
	}

	private struct OverlapLabelStyle: LabelStyle {
		func makeBody(configuration: Configuration) -> some View {
			HStack(spacing: 3) {
				configuration.icon
				configuration.title
			}
		}
	}
}

/// Each sentence's bounds in trim mode, by its point.
private struct SentenceBounds: PreferenceKey {
	static let defaultValue: [NotesTrimPoint: Anchor<CGRect>] = [:]

	static func reduce(value: inout [NotesTrimPoint: Anchor<CGRect>], nextValue: () -> [NotesTrimPoint: Anchor<CGRect>]) {
		value.merge(nextValue()) { $1 }
	}
}

/// A transcript drag in progress, in the transcript's coordinates. Not observed: it is read by the gesture, not
/// drawn.
private final class TrimDrag {
	/// Where each sentence is, refreshed on every layout.
	var frames: [NotesTrimPoint: CGRect] = [:]
	/// The part of the transcript the scroll view shows.
	var visible: CGRect = .zero
	var anchor: NotesTrimPoint?
	/// Shift was held at the press: the drag extends the selection from its anchor.
	var extend = false
	/// The sentence last selected, so a drag step within one sentence sends nothing.
	var last: NotesTrimPoint?
	var pointer: CGPoint = .zero
	var scrolling: Task<Void, Never>?

	static let edge: CGFloat = 28

	/// How far the pointer is into the scrolling band at the top (negative) or bottom (positive); 0 outside it.
	var overshoot: CGFloat {
		guard visible.height > Self.edge * 3 else { return 0 }
		if pointer.y < visible.minY + Self.edge { return pointer.y - (visible.minY + Self.edge) }
		if pointer.y > visible.maxY - Self.edge { return pointer.y - (visible.maxY - Self.edge) }
		return 0
	}

	func stopScrolling() {
		scrolling?.cancel()
		scrolling = nil
	}

	func nearest(to location: CGPoint) -> NotesTrimPoint? {
		var best: (NotesTrimPoint, CGFloat)?
		for (point, frame) in frames {
			let dx = max(frame.minX - location.x, 0, location.x - frame.maxX)
			let dy = max(frame.minY - location.y, 0, location.y - frame.maxY)
			let distance = dx * dx + dy * dy
			if best == nil || distance < best!.1 { best = (point, distance) }
		}
		return best?.0
	}
}

/// Sentences laid out like running text: each sentence is a view of its own so it can be selected, placed on
/// the line after the one before it when it fits and on a line of its own (wrapping inside itself) when it
/// doesn't.
struct SentenceFlow: Layout {
	var lineSpacing: CGFloat = 3

	private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
		var frames: [CGRect] = []
		var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, usedWidth: CGFloat = 0
		for subview in subviews {
			var size = subview.sizeThatFits(.unspecified)
			if x > 0, x + size.width > width {
				x = 0
				y += lineHeight + lineSpacing
				lineHeight = 0
			}
			if size.width > width {
				// Longer than a line: it wraps inside itself, and the next sentence starts below it.
				size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
				frames.append(CGRect(origin: CGPoint(x: 0, y: y), size: size))
				y += size.height + lineSpacing
				x = 0
				lineHeight = 0
				usedWidth = max(usedWidth, size.width)
				continue
			}
			frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
			x += size.width
			lineHeight = max(lineHeight, size.height)
			usedWidth = max(usedWidth, x)
		}
		return (frames, CGSize(width: usedWidth, height: max(y + lineHeight - (lineHeight == 0 ? lineSpacing : 0), 0)))
	}

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
		let result = arrange(width: width, subviews: subviews)
		return CGSize(width: proposal.width ?? result.size.width, height: result.size.height)
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		let result = arrange(width: bounds.width, subviews: subviews)
		for (subview, frame) in zip(subviews, result.frames) {
			subview.place(
				at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
				proposal: ProposedViewSize(width: frame.width, height: frame.height)
			)
		}
	}

	/// The first sentence sits at the top left, so its baseline is the row's.
	func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
		guard guide == .firstTextBaseline, let first = subviews.first else { return nil }
		let size = first.sizeThatFits(.unspecified)
		return first.dimensions(in: ProposedViewSize(width: min(size.width, bounds.width), height: nil))[guide]
	}
}

/// The Trim timeline (DESIGN.md "Notes trimming", option B): one block per sentence, coloured by speaker,
/// left-out stretches dimmed with an eye-slash, the selection a raised band with handles that snap to
/// sentences; dragging across the strip selects a stretch. It shares its selection with the transcript below.
struct NotesTrimStrip: View {
	var sentences: [NotesSentenceItem]
	var sessionSeconds: Double?
	var selection: NotesFeature.TrimSelection?
	var onSelect: (NotesTrimPoint, NotesTrimPoint) -> Void

	private static let height: CGFloat = 36
	private static let barHeight: CGFloat = 22
	private static let space = "notes-trim-strip"

	private var total: Double { max(sentences.last?.end ?? 0, 1) }

	private var timeline: [NotesTimelineSentence] {
		sentences.map {
			NotesTimelineSentence(point: $0.point, speaker: $0.paragraph.speaker, start: $0.start, end: $0.end, trimIndex: $0.trimIndex)
		}
	}

	/// The selection's start and end on the timeline.
	private var span: (start: Double, end: Double)? {
		guard let selection,
		      let first = sentences.first(where: { $0.point == selection.start }),
		      let last = sentences.first(where: { $0.point == selection.end }) else { return nil }
		return (first.start, last.end)
	}

	var body: some View {
		VStack(spacing: 4) {
			GeometryReader { proxy in
				let width = proxy.size.width
				ZStack(alignment: .topLeading) {
					Canvas { context, size in blocks(context, size) }
						.gesture(
							// A click selects the sentence under it; a drag selects every sentence it crosses.
							DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)).onChanged { value in
								guard let from = sentence(atX: value.startLocation.x, width: width),
								      let to = sentence(atX: value.location.x, width: width),
								      selection != .init(from, to) else { return }
								onSelect(from, to)
							}
						)
					if let selection, let span {
						let x0 = span.start / total * width, x1 = span.end / total * width
						RoundedRectangle(cornerRadius: 3)
							.stroke(Color.black.opacity(0.85), lineWidth: 2)
							.background(Color.white.opacity(0.25))
							.frame(width: max(x1 - x0, 2), height: 28)
							.position(x: (x0 + x1) / 2, y: Self.height / 2)
							.allowsHitTesting(false)
						handle(at: x0, label: "Start of the selection")
							.gesture(handleDrag(width: width) { seconds in
								if let point = NotesTimeline.nearestStart(to: seconds, in: timeline) { onSelect(point, selection.end) }
							})
						handle(at: x1, label: "End of the selection")
							.gesture(handleDrag(width: width) { seconds in
								if let point = NotesTimeline.nearestEnd(to: seconds, in: timeline) { onSelect(selection.start, point) }
							})
					}
				}
				.coordinateSpace(name: Self.space)
			}
			.frame(height: Self.height)
			HStack {
				Text(NotesTimeline.clock(0))
					.font(.system(size: 10))
					.foregroundStyle(.tertiary)
				Spacer()
				if let span {
					Text("about \(NotesTimeline.clock(span.start)) – \(NotesTimeline.clock(span.end)) selected")
						.font(.system(size: 11, weight: .medium))
				}
				Spacer()
				Text(NotesTimeline.clock(sessionSeconds ?? total))
					.font(.system(size: 10))
					.foregroundStyle(.tertiary)
			}
		}
	}

	private func blocks(_ context: GraphicsContext, _ size: CGSize) {
		var context = context
		let y = (size.height - Self.barHeight) / 2
		context.clip(to: Path(roundedRect: CGRect(x: 0, y: y, width: size.width, height: Self.barHeight), cornerRadius: 4))
		var eyeDrawn = Set<Int>()
		for sentence in sentences {
			let x0 = sentence.start / total * size.width, x1 = sentence.end / total * size.width
			let gap: CGFloat = x1 - x0 > 4 ? 1 : 0
			let rect = CGRect(x: x0, y: y, width: max(x1 - x0 - gap, 0.5), height: Self.barHeight)
			if let trim = sentence.trimIndex {
				context.fill(Path(rect), with: .color(Color.gray.opacity(0.55)))
				if !eyeDrawn.contains(trim) {
					eyeDrawn.insert(trim)
					context.draw(
						context.resolve(Image(systemName: "eye.slash").renderingMode(.template)),
						at: CGPoint(x: x0 + 9, y: size.height / 2)
					)
				}
			} else {
				context.fill(Path(rect), with: .color(color(sentence)))
			}
		}
	}

	private func color(_ sentence: NotesSentenceItem) -> Color {
		let paragraph = sentence.paragraph
		guard let speaker = paragraph.speaker, paragraph.label != nil else { return Color.gray.opacity(0.4) }
		return paragraph.isUser ? Color.accentColor.opacity(0.55) : NotesSpeakerTranscript.tint(paragraph, speaker: speaker).opacity(0.5)
	}

	private func handle(at x: CGFloat, label: String) -> some View {
		RoundedRectangle(cornerRadius: 2)
			.fill(Color.black.opacity(0.85))
			.frame(width: 10, height: Self.height - 2)
			.overlay(
				Image(systemName: "chevron.left.chevron.right")
					.font(.system(size: 6, weight: .bold))
					.foregroundStyle(.white)
					.rotationEffect(.degrees(90))
			)
			.frame(width: 22, height: Self.height)
			.contentShape(Rectangle())
			.position(x: x, y: Self.height / 2)
			.accessibilityLabel(label)
	}

	private func sentence(atX x: CGFloat, width: CGFloat) -> NotesTrimPoint? {
		let seconds = min(max(x / max(width, 1), 0), 1) * total
		return sentences.first { $0.start <= seconds && seconds < $0.end }?.point
			?? NotesTimeline.nearestStart(to: seconds, in: timeline)
	}

	private func handleDrag(width: CGFloat, _ move: @escaping (Double) -> Void) -> some Gesture {
		DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
			.onChanged { value in
				move(min(max(value.location.x / max(width, 1), 0), 1) * total)
			}
	}
}

/// The naming popover (option A): a name, "Recognise this voice in future sessions" (on by default), Cancel
/// and Save. A voice that is already saved has no box: renaming it renames the saved voice too.
struct NotesSpeakerNamingForm: View {
	var paragraph: NotesSpeakerParagraph
	var onSave: (String, Bool) -> Void
	var onCancel: () -> Void
	@State private var name: String
	@State private var remember = true
	@FocusState private var nameFocused: Bool

	init(paragraph: NotesSpeakerParagraph, onSave: @escaping (String, Bool) -> Void, onCancel: @escaping () -> Void) {
		self.paragraph = paragraph
		self.onSave = onSave
		self.onCancel = onCancel
		let label = paragraph.label ?? ""
		let numbered = paragraph.speaker.map { label == "Speaker \($0)" } ?? true
		_name = State(initialValue: numbered ? "" : label)
	}

	private var voiceKnown: Bool { paragraph.recognised || paragraph.voiceSaved }
	private var cleaned: String? { SpeakerNaming.cleaned(name) }

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			VStack(alignment: .leading, spacing: 2) {
				Text("Name this speaker")
					.font(.headline)
				Text("Heard for \(Self.duration(paragraph.seconds)) in this session")
					.font(.callout)
					.foregroundStyle(.secondary)
			}
			TextField("Name", text: $name, prompt: Text("Name, or “Me” if it’s you"))
				.textFieldStyle(.roundedBorder)
				.focused($nameFocused)
				.onSubmit(save)
			if voiceKnown {
				Text("This voice is saved on this Mac, so the new name is used in future sessions too.")
					.font(.callout)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			} else {
				Toggle("Recognise this voice in future sessions", isOn: $remember)
					.toggleStyle(.checkbox)
			}
			HStack {
				Spacer()
				Button("Cancel", action: onCancel)
					.keyboardShortcut(.cancelAction)
				Button("Save", action: save)
					.keyboardShortcut(.defaultAction)
					.disabled(cleaned == nil)
			}
		}
		.padding(16)
		.frame(width: 320)
		.onAppear { nameFocused = true }
	}

	private func save() {
		guard cleaned != nil else { return }
		onSave(name, voiceKnown || remember)
	}

	/// "5 min 40 s", "40 s".
	static func duration(_ seconds: Double) -> String {
		let total = max(Int(seconds.rounded()), 1)
		let minutes = total / 60, rest = total % 60
		if minutes == 0 { return "\(rest) s" }
		return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
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
