import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct PracticeView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<PracticeFeature>
	@State private var researchModelText = ""

	var body: some View {
		Form {
			readAloudSection
			sentTextSection
			vocabularySection
			researchSection
		}
		.formStyle(.grouped)
		.onAppear { researchModelText = store.hexSettings.practiceResearchModel }
		.sheet(item: Binding(
			get: { store.session },
			set: { if $0 == nil { store.send(.endSession) } }
		)) { _ in
			PracticeSessionView(store: store)
		}
		.enableInjection()
	}

	// MARK: - Read aloud

	private var readAloudSection: some View {
		let script = PracticeScript.bundled
		let log = store.practiceLog
		let recorded = log.recordings.count
		let reached = log.coverage(in: script)
		let next = log.nextLine(in: script)
		return Section {
			Label {
				Text("Read lines aloud to teach the speech model your voice. The first few cover every English sound, then sound combinations, then the jargon, code talk and numbers you actually dictate. Stop whenever you like: each line is saved as you go, and the most useful ones come first.")
					.settingsCaption()
				if !script.lines.isEmpty {
					ProgressView(value: Double(recorded), total: Double(script.lines.count))
					Text(Self.progressSummary(log: log, reached: reached, total: script.lines.count))
						.font(.callout)
				}
				HStack {
					if let next {
						Button(recorded == 0 ? "Start practice" : "Continue") { store.send(.startSession) }
							.buttonStyle(.borderedProminent)
						Text("Next: \(next.stage.title)").settingsCaption()
					} else if !script.lines.isEmpty {
						Text("Every line is recorded or skipped.").settingsCaption()
					}
					Spacer()
					if recorded > 0 {
						Button("Show recordings") { NSWorkspace.shared.open(URL.practiceFolderURL) }
					}
				}
				.padding(.top, 2)
			} icon: {
				Image(systemName: "text.bubble")
			}
		} header: {
			Text("Read aloud")
		}
	}

	static func progressSummary(log: PracticeLog, reached: PracticeLine?, total: Int) -> String {
		var parts = ["\(log.recordings.count) of \(total) lines"]
		if let reached {
			parts.append("\(reached.soundsCovered) of \(PracticeScript.phonemeCount) sounds")
			parts.append("\(reached.pairsCoveredPercent)% of sound pairs")
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
				Text("After a paste, pressing Enter in the same text box keeps the version you sent, edits and all. Nothing in History changes, and it stays on this Mac. Not in terminals.")
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
					Text("Nothing new stood out. Your vocabulary already covers what you say.")
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
					Text("Want me to check your history for words to add to your vocabulary?")
					Text("Looks at what speech recognition heard next to what you kept, and suggests names and jargon it keeps getting wrong. Sends recent dictations to your rewrite endpoint (\(store.hexSettings.rewritePrimary.model)).")
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
				Text("Ask OmniRoute what research exists on personalized training: which speech and text models capture enough detail from your own transcriptions to be worth tuning, how much data that takes, and what to collect now.")
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
				Text("Use a model that can search the web. Goes to your primary endpoint with your history counts, never the text.")
					.settingsCaption()
			} icon: {
				Image(systemName: "books.vertical")
			}

			if store.isResearching, store.research.isEmpty {
				HStack(spacing: 8) {
					ProgressView().controlSize(.small)
					Text("Searching… this can take a minute.").settingsCaption()
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
