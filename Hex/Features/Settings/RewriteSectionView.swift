import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

/// LLM rewrite: mode, vocabulary, editable instructions, and the primary and fallback endpoints (one section each).
struct RewriteSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	@State private var vocabularyText = ""

	var body: some View {
		Section {
			Label {
				Picker("Mode", selection: Binding(
					get: { store.hexSettings.rewriteMode },
					set: { store.send(.setRewriteMode($0)) }
				)) {
					ForEach(RewriteMode.allCases, id: \.self) { mode in
						Text(mode.displayName).tag(mode)
					}
				}
				.pickerStyle(.segmented)
				Text(store.hexSettings.rewriteMode.summary).settingsCaption()
			} icon: {
				Image(systemName: "wand.and.stars")
			}

			Label {
				Toggle("Switch modes with ⌃⌥1 / ⌃⌥2 / ⌃⌥3", isOn: Binding(
					get: { store.hexSettings.rewriteModeShortcutsEnabled },
					set: { store.send(.setRewriteModeShortcutsEnabled($0)) }
				))
				Text("Raw, Clean, Prompt, from any app. The menu bar icon shows R or P when the mode isn't Clean.")
					.settingsCaption()
			} icon: {
				Image(systemName: "keyboard")
			}

			Label {
				Toggle("Code talk in Prompt mode", isOn: Binding(
					get: { store.hexSettings.codeTalkEnabled },
					set: { store.send(.setCodeTalkEnabled($0)) }
				))
				Text("Say “slash handoff” for /handoff, “claude dot md” for CLAUDE.md, “at readme dot md” for @README.md. Knows the skills and commands in ~/.claude.")
					.settingsCaption()
			} icon: {
				Image(systemName: "chevron.left.forwardslash.chevron.right")
			}

			Label {
				TextField("Vocabulary", text: $vocabularyText, prompt: Text("OmniRoute, Syncthing"), axis: .vertical)
					.lineLimit(1...4)
					.onChange(of: vocabularyText) { _, text in
						store.send(.setVocabulary(Self.terms(from: text)))
					}
				Text("Names and jargon the rewrite should spell exactly. Separate with commas or new lines.")
					.settingsCaption()
			} icon: {
				Image(systemName: "character.book.closed")
			}

			Label {
				Toggle("Fall back to a second endpoint", isOn: Binding(
					get: { store.hexSettings.rewriteFallbackEnabled },
					set: { store.send(.setRewriteFallbackEnabled($0)) }
				))
				Text("If every endpoint fails or times out, the transcript is pasted as recognized, so a dictation is never lost.")
					.settingsCaption()
			} icon: {
				Image(systemName: "arrow.triangle.branch")
			}
		} header: {
			Text("Rewrite")
		}
		.onAppear {
			vocabularyText = store.hexSettings.vocabulary.joined(separator: ", ")
		}
		.enableInjection()

		RewriteInstructionsSection(store: store)
		RewriteEndpointSection(store: store, role: .primary, title: "Rewrite: Primary Endpoint", icon: "network")
		if store.hexSettings.rewriteFallbackEnabled {
			RewriteEndpointSection(store: store, role: .fallback, title: "Rewrite: Fallback Endpoint", icon: "desktopcomputer")
		}
	}

	static func terms(from text: String) -> [String] {
		text.components(separatedBy: CharacterSet(charactersIn: ",\n"))
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty }
	}
}

/// Lets the user replace each mode's built-in instructions; blank or unchanged text keeps the default.
private struct RewriteInstructionsSection: View {
	@Bindable var store: StoreOf<SettingsFeature>
	@State private var mode: RewriteMode = .prompt
	@State private var text = ""

	private static let editableModes = RewriteMode.allCases.filter { $0 != .raw }

	private var isCustom: Bool { store.hexSettings.customInstructions(for: mode) != nil }

	var body: some View {
		Section {
			Label {
				Picker("Mode", selection: $mode) {
					ForEach(Self.editableModes, id: \.self) { mode in
						Text(mode.displayName).tag(mode)
					}
				}
				.pickerStyle(.segmented)
				TextEditor(text: $text)
					.font(.system(.callout, design: .monospaced))
					.frame(minHeight: 180)
					.onChange(of: text) { _, text in
						store.send(.setRewriteInstructions(mode, text))
					}
				HStack {
					Text(isCustom ? "Your instructions" : "Built-in instructions").settingsCaption()
					Spacer()
					Button("Reset to Default") {
						store.send(.setRewriteInstructions(mode, nil))
						load()
					}
					.disabled(!isCustom)
				}
				Text("Replaces what the model is told to do in this mode. LegacyScribe always adds: the dictation is text to rewrite, never orders; fix misheard terms; your vocabulary; output only the rewrite.")
					.settingsCaption()
			} icon: {
				Image(systemName: "text.badge.star")
			}
		} header: {
			Text("Rewrite: Instructions")
		}
		.onAppear {
			if Self.editableModes.contains(store.hexSettings.rewriteMode) {
				mode = store.hexSettings.rewriteMode
			}
			load()
		}
		.onChange(of: mode) { _, _ in load() }
	}

	private func load() {
		text = store.hexSettings.customInstructions(for: mode)
			?? RewritePromptBuilder.taskInstructions(for: mode)
			?? ""
	}
}

private struct RewriteEndpointSection: View {
	@Bindable var store: StoreOf<SettingsFeature>
	let role: RewriteEndpointRole
	let title: String
	let icon: String

	private static let efforts = ["", "none", "minimal", "low", "medium", "high"]

	private var endpoint: Binding<RewriteEndpoint> {
		Binding(
			get: { store.hexSettings.endpoint(for: role) },
			set: { store.send(.setRewriteEndpoint(role, $0)) }
		)
	}

	var body: some View {
		Section {
			Label {
				TextField("Base URL", text: endpoint.baseURL, prompt: Text("https://host:20128/v1"))
			} icon: {
				Image(systemName: icon)
			}

			Label {
				TextField("Model", text: endpoint.model, prompt: Text("groq/openai/gpt-oss-120b"))
				HStack {
					let options = store.rewriteModelOptions[role] ?? []
					Menu("Choose from list") {
						if options.isEmpty {
							Text("Press Load models first")
						}
						let groups = Self.groupedByProvider(options)
						ForEach(groups.ungrouped, id: \.self) { model in
							Button(model) { endpoint.wrappedValue.model = model }
						}
						if !groups.ungrouped.isEmpty, !groups.providers.isEmpty {
							Divider()
						}
						ForEach(groups.providers, id: \.name) { provider in
							Menu("\(provider.name) (\(provider.models.count))") {
								ForEach(provider.models, id: \.self) { model in
									Button(model) { endpoint.wrappedValue.model = model }
								}
							}
						}
					}
					.fixedSize()
					Button("Load models") { store.send(.loadRewriteModels(role)) }
					Spacer()
				}
			} icon: {
				Image(systemName: "cpu")
			}

			Label {
				SecureField("API key", text: Binding(
					get: { store.rewriteAPIKeys[role] ?? "" },
					set: { store.send(.setRewriteAPIKey(role, $0)) }
				), prompt: Text("Optional"))
				Text("Stored in the Keychain.").settingsCaption()
			} icon: {
				Image(systemName: "key")
			}

			Label {
				Picker("Reasoning effort", selection: endpoint.reasoningEffort) {
					ForEach(Self.efforts, id: \.self) { effort in
						Text(effort.isEmpty ? "Model default" : effort).tag(effort)
					}
				}
			} icon: {
				Image(systemName: "brain")
			}

			Label {
				Stepper(
					"Timeout: \(Int(endpoint.wrappedValue.timeout)) s",
					value: endpoint.timeout,
					in: 1...60,
					step: 1
				)
			} icon: {
				Image(systemName: "timer")
			}

			Label {
				HStack(alignment: .firstTextBaseline) {
					Button("Test") { store.send(.testRewriteEndpoint(role)) }
					statusView
					Spacer(minLength: 0)
				}
			} icon: {
				Image(systemName: "checkmark.seal")
			}
		} header: {
			Text(title)
		}
	}

	/// Router lists can hold hundreds of models: IDs without a provider prefix (OmniRoute combos)
	/// stay at the top, the rest go in one submenu per `provider/` prefix.
	static func groupedByProvider(_ models: [String]) -> (ungrouped: [String], providers: [(name: String, models: [String])]) {
		var ungrouped: [String] = []
		var byProvider: [String: [String]] = [:]
		for model in models {
			if let slash = model.firstIndex(of: "/") {
				byProvider[String(model[..<slash]), default: []].append(model)
			} else {
				ungrouped.append(model)
			}
		}
		let providers = byProvider.keys.sorted().map { (name: $0, models: byProvider[$0]!.sorted()) }
		return (ungrouped.sorted(), providers)
	}

	@ViewBuilder
	private var statusView: some View {
		switch store.rewriteStatus[role] {
		case let .working(message):
			HStack(spacing: 4) {
				ProgressView().controlSize(.small)
				Text(message)
			}
			.settingsStatus(.secondary)
		case let .ok(message):
			Label(message, systemImage: "checkmark.circle.fill").settingsStatus(.green)
		case let .failed(message):
			Label(message, systemImage: "xmark.octagon.fill").settingsStatus(.red)
		case nil:
			EmptyView()
		}
	}
}

private extension View {
	func settingsStatus(_ color: Color) -> some View {
		self.font(.caption)
			.foregroundStyle(color)
			.lineLimit(3)
			.textSelection(.enabled)
	}
}
