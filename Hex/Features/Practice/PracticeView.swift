import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct PracticeView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<PracticeFeature>
	var transcription: StoreOf<TranscriptionFeature>
	@State private var researchModelText = ""
	@State private var confirmingClear = false

	var body: some View {
		Form {
			readAloudSection
			if !store.practiceLog.recordings.isEmpty {
				hearingSection
			}
			sentTextSection
			vocabularySection
			// Research needs a web-search model, which only a router such as OmniRoute offers.
			if store.hexSettings.rewritePrimary.provider == .custom {
				researchSection
			}
		}
		.formStyle(.grouped)
		.onAppear {
			researchModelText = store.hexSettings.practiceResearchModel
			store.send(.scanPracticeFolder)
		}
		.sheet(item: Binding(
			get: { store.session },
			set: { if $0 == nil { store.send(.endSession) } }
		)) { _ in
			PracticeSessionView(store: store, transcription: transcription)
		}
		.enableInjection()
	}

	// MARK: - Read aloud

	private var readAloudSection: some View {
		let script = PracticeScript.bundled
		let log = store.practiceLog
		let recorded = log.recordings.count
		let allRecorded = !script.lines.isEmpty && script.lines.allSatisfy { log.recordings[$0.id] != nil }
		return Section {
			Label {
				Text("Read a few lines aloud so the speech model learns your voice. Each set has up to ten lines: the sounds you've recorded least, sound combinations you haven't covered yet, your own jargon and numbers, and one ordinary line. Each line is saved as soon as you read it, so you can stop at any point.")
					.settingsCaption()
				if !script.lines.isEmpty {
					ProgressView(value: Double(recorded), total: Double(script.lines.count))
					Text(Self.progressSummary(log: log, script: script))
						.font(.callout)
				}
				if allRecorded {
					Text("You've recorded every line.").settingsCaption()
				} else if !script.lines.isEmpty {
					HStack {
						Button {
							store.send(.startSession(endless: false))
						} label: {
							Label("Start a set", systemImage: "mic.fill")
						}
						.buttonStyle(.borderedProminent)
						Button("Endless") { store.send(.startSession(endless: true)) }
						Spacer()
					}
					.controlSize(.large)
					.padding(.top, 2)
					Text("Endless keeps giving you lines you haven't seen until you stop.")
						.settingsCaption()
				}
			} icon: {
				Image(systemName: "text.bubble")
			}

			if recorded > 0 || !store.practiceFiles.isEmpty {
				storageRow(log: log)
			}
		} header: {
			Text("Read aloud")
		}
	}

	private func storageRow(log: PracticeLog) -> some View {
		let files = store.practiceFiles
		let total = files.values.reduce(0, +)
		let trained = log.trainedWithAudio
		let trainedBytes = trained.reduce(Int64(0)) { $0 + (files[$1.audioFileName] ?? 0) }
		let untrained = log.untrained.count
		let cleared = log.recordings.values.filter { !$0.hasAudio }.count
		var counts: [String] = []
		if untrained > 0 { counts.append("\(untrained) not trained yet") }
		if !trained.isEmpty { counts.append("\(trained.count) trained (\(Self.bytes(trainedBytes)))") }
		if cleared > 0 { counts.append("\(cleared) with audio deleted") }
		return Label {
			HStack {
				Text("Recordings use \(Self.bytes(total))")
				Spacer()
				Button("Show in Finder") { NSWorkspace.shared.open(URL.practiceFolderURL) }
			}
			if !counts.isEmpty {
				Text(counts.joined(separator: " · ")).settingsCaption()
			}
			HStack {
				Button("Mark all as trained") { store.send(.markTrained) }
					.disabled(untrained == 0)
				Button("Delete trained audio", role: .destructive) { confirmingClear = true }
					.disabled(trained.isEmpty)
				Spacer()
			}
			.controlSize(.large)
			Text("Silence is cut from each recording when it's saved. After you train a model on these recordings, mark them as trained. Deleting trained audio frees the space, and those lines stay counted as recorded so they won't come up again.")
				.settingsCaption()
		} icon: {
			Image(systemName: "internaldrive")
		}
		.confirmationDialog(
			"Delete the audio of \(trained.count) trained line\(trained.count == 1 ? "" : "s")?",
			isPresented: $confirmingClear
		) {
			Button("Delete \(Self.bytes(trainedBytes))", role: .destructive) { store.send(.clearTrainedAudio) }
		} message: {
			Text("The recordings can't be used again for training or benchmarks.")
		}
	}

	static func bytes(_ count: Int64) -> String {
		ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
	}

	static func progressSummary(log: PracticeLog, script: PracticeScript) -> String {
		let coverage = log.coverage(in: script)
		var parts = ["\(log.recordings.count) of \(script.lines.count) lines"]
		if log.recordings.count > 0 {
			parts.append("\(coverage.soundsCovered) of \(PracticeScript.phonemeCount) sounds")
			let pairs = max(PracticeScript.bundledPairCount, 1)
			parts.append("\(100 * coverage.pairs.count / pairs)% of sound combinations")
		}
		let minutes = Int((log.recordedSeconds / 60).rounded())
		if log.recordedSeconds > 0 {
			parts.append(minutes < 1 ? "under a minute of audio" : "\(minutes) min of audio")
		}
		if let rate = log.overallWordErrorRate {
			parts.append(String(format: "engine heard %.0f%% of words right", max(0, 1 - rate) * 100))
		}
		return parts.joined(separator: " · ")
	}

	// MARK: - Hearing check

	private var hearingSection: some View {
		let script = PracticeScript.bundled
		let terms = Dictionary(script.lines.map { ($0.id, $0.terms) }, uniquingKeysWith: { first, _ in first })
		let summary = store.practiceLog.gradeSummary { terms[$0] ?? [] }
		let checked = store.practiceLog.recordings.values.filter { $0.secondOpinion != nil }.count
		return Section {
			Label {
				Text("Checks how much of each line the speech engine heard right, aiming for 95% or better. A second engine of a different kind listens too: when both hear the same other word, that's most likely how you said it, so it doesn't count against the engine. New words such as product names don't count either; add them to your vocabulary.")
					.settingsCaption()
				if !summary.lines.isEmpty {
					Text(String(
						format: "Heard %.0f%% of %d words · %d of %d lines at 95%% or better",
						summary.heard * 100, summary.words, summary.passing, summary.lines.count
					))
					.font(.callout)
					if checked < summary.lines.count {
						Text("\(checked) of \(summary.lines.count) lines have a second opinion so far.").settingsCaption()
					}
				}
				HStack {
					if let progress = store.recordingCheck {
						ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
							.frame(maxWidth: 200)
						Text("\(progress.done) of \(progress.total)").settingsCaption().monospacedDigit()
						Button("Stop") { store.send(.cancelRecordingCheck) }
					} else {
						Button("Check my recordings") { store.send(.checkRecordings) }
					}
					Spacer()
				}
				if let note = store.recordingCheckNote {
					Text(note).settingsCaption()
				}
			} icon: {
				Image(systemName: "ear")
			}

			if !summary.saidDifferently.isEmpty {
				Label {
					Text("Words you may have read differently").font(.callout)
					Text(Self.pairs(summary.saidDifferently)).settingsCaption().textSelection(.enabled)
					Text("Both engines heard these. Practice them, or redo those lines so the recordings match their text.")
						.settingsCaption()
				} icon: {
					Image(systemName: "person.wave.2")
				}
			}

			if !summary.newWords.isEmpty {
				Label {
					Text("New words the engine spelled its own way").font(.callout)
					Text(Self.pairs(summary.newWords)).settingsCaption().textSelection(.enabled)
				} icon: {
					Image(systemName: "character.book.closed")
				}
			}

			ForEach(summary.belowMark.prefix(10)) { line in
				Label {
					Text(line.text).font(.callout)
					Text(String(format: "Heard %.0f%%: ", line.grade.heard * 100) + Self.pairs(line.grade.differences.filter { $0.kind == .misheard }))
						.settingsCaption()
				} icon: {
					Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
				}
			}
		} header: {
			Text("How well the engine hears you")
		}
	}

	/// "equatable → equitable, ∅ → feel"
	static func pairs(_ differences: [PracticeGrade.Difference]) -> String {
		differences.map { "\($0.expected ?? "(nothing)") → \($0.heard ?? "(nothing)")" }.joined(separator: ", ")
	}

	// MARK: - Sent text

	private var recentEdited: [SentEdit] {
		Array(store.sentEdits.edits.reversed().filter(\.wasEdited).prefix(10))
	}

	private var sentTextSection: some View {
		Section {
			Label {
				Toggle("Remember what I send", isOn: Binding(
					get: { store.hexSettings.captureSentEdits },
					set: { store.send(.setCaptureSentEdits($0)) }
				))
				Text("After a paste, pressing Enter in the same text box saves the version you sent, including your edits. History stays as it was, everything stays on this Mac, and terminals are skipped.")
					.settingsCaption()
			} icon: {
				Image(systemName: "return")
			}

			let edits = store.sentEdits.edits
			if edits.isEmpty {
				Text("Nothing captured yet. Dictate into a chat or text box, then press Enter.")
					.settingsCaption()
			} else {
				Text("\(edits.count) sent, \(edits.filter(\.wasEdited).count) changed by you before sending.")
					.font(.callout)
				ForEach(recentEdited) { edit in
					SentEditRow(edit: edit)
				}
			}
		} header: {
			Text("What you send")
		}
	}

	// MARK: - Vocabulary

	private var vocabularySection: some View {
		Section {
			if store.isCheckingHistory {
				HStack(spacing: 8) {
					ProgressView().controlSize(.small)
					Text("Reading your history…").settingsCaption()
				}
			} else if let suggestions = store.suggestions, store.checkError == nil {
				if suggestions.isEmpty {
					Text("No new words found.")
						.settingsCaption()
				}
				ForEach(suggestions) { suggestion in
					SuggestionRow(
						suggestion: suggestion,
						add: { store.send(.addSuggestion(suggestion)) },
						dismiss: { store.send(.dismissSuggestion(suggestion)) }
					)
				}
				HStack {
					if let model = store.checkedWith {
						Text("Checked by \(model)").settingsCaption()
					}
					Spacer()
					Button("Check again") { store.send(.checkHistory) }
				}
			} else {
				Label {
					Text("Check your history for words to add to your vocabulary.")
					Text("Compares what speech recognition heard with what you kept, and suggests names and jargon it gets wrong. Recent dictations are sent to your rewrite endpoint (\(store.hexSettings.rewritePrimary.model)).")
						.settingsCaption()
					if let error = store.checkError {
						Text(error).font(.caption).foregroundStyle(.red)
					}
					Button("Check my history") { store.send(.checkHistory) }
						.buttonStyle(.borderedProminent)
						.padding(.top, 2)
				} icon: {
					Image(systemName: "text.badge.checkmark")
				}
			}
		} header: {
			Text("Vocabulary from your history")
		}
	}

	// MARK: - Research

	private var dashboardURL: URL? {
		guard var components = URLComponents(string: store.hexSettings.rewritePrimary.baseURL) else { return nil }
		components.path = "/"
		components.query = nil
		return components.url
	}

	private var researchSection: some View {
		Section {
			Label {
				Text("Ask OmniRoute about research on training speech and text models on your own recordings: which models are worth tuning, how much data it takes, and what to collect now.")
					.settingsCaption()
				HStack {
					TextField("Model", text: $researchModelText, prompt: Text("wp-search"))
						.frame(maxWidth: 200)
						.onSubmit { store.send(.setResearchModel(researchModelText)) }
						.onChange(of: researchModelText) { _, text in store.send(.setResearchModel(text)) }
					Spacer()
					if let dashboardURL {
						Link("Open OmniRoute", destination: dashboardURL)
					}
					if store.isResearching {
						Button("Stop") { store.send(.cancelResearch) }
					} else {
						Button("Ask OmniRoute") { store.send(.askResearch) }
							.buttonStyle(.borderedProminent)
					}
				}
				Text("Use a model that can search the web. Your primary endpoint gets how many dictations and edits you have. Their text stays on this Mac.")
					.settingsCaption()
			} icon: {
				Image(systemName: "books.vertical")
			}

			if store.isResearching, store.research.isEmpty {
				HStack(spacing: 8) {
					ProgressView().controlSize(.small)
					Text("Searching. This can take a minute.").settingsCaption()
				}
			}
			if let error = store.researchError {
				Text(error).font(.caption).foregroundStyle(.red)
			}
			if !store.research.isEmpty {
				Text(Self.markdown(store.research))
					.textSelection(.enabled)
					.font(.callout)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
		} header: {
			Text("Research")
		}
	}

	static func markdown(_ text: String) -> AttributedString {
		(try? AttributedString(
			markdown: text,
			options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
		)) ?? AttributedString(text)
	}
}

private struct SentEditRow: View {
	var edit: SentEdit

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack {
				Text(edit.appName ?? edit.bundleID ?? "Unknown app")
				Text(edit.timestamp, style: .relative)
				Spacer()
				if let mode = edit.mode {
					Text(mode.displayName)
				}
			}
			.font(.caption)
			.foregroundStyle(.secondary)
			Text(edit.pasted)
				.font(.callout)
				.foregroundStyle(.secondary)
				.strikethrough(color: .secondary.opacity(0.5))
				.lineLimit(4)
			Text(edit.sent)
				.font(.callout)
				.lineLimit(6)
				.textSelection(.enabled)
		}
		.padding(.vertical, 2)
	}
}

private struct SuggestionRow: View {
	var suggestion: VocabularySuggestion
	var add: () -> Void
	var dismiss: () -> Void

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			VStack(alignment: .leading, spacing: 2) {
				Text(suggestion.term).font(.body.weight(.medium))
				if !suggestion.heardAs.isEmpty {
					Text("Heard as " + suggestion.heardAs.map { "“\($0)”" }.joined(separator: ", "))
						.settingsCaption()
				}
				if !suggestion.reason.isEmpty {
					Text(suggestion.reason).settingsCaption()
				}
			}
			Spacer()
			Button("Add", action: add)
			Button(action: dismiss) {
				Image(systemName: "xmark")
			}
			.buttonStyle(.borderless)
			.help("Not this one")
		}
	}
}
