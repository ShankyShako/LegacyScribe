import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

/// The AI Rewrite page: what a dictation becomes (mode, vocabulary), which AI does the rewriting, and an
/// Advanced area for shortcuts, instructions and per-endpoint tuning. The simple path is one choice
/// (download a model, or paste a key) and one button.
struct RewriteSettingsView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	@State private var vocabularyText = ""
	@State private var showsAdvanced = false

	var body: some View {
		Form {
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
					TextField("Words to spell exactly", text: $vocabularyText, prompt: Text("Names, products, jargon"), axis: .vertical)
						.lineLimit(1...4)
						.onChange(of: vocabularyText) { _, text in
							store.send(.setVocabulary(Self.terms(from: text)))
						}
					Text("The AI spells these the way you write them. Separate with commas or new lines.")
						.settingsCaption()
				} icon: {
					Image(systemName: "character.book.closed")
				}

				Label {
					Toggle("Legacy: say \u{201C}legacy\u{201D} first to give an instruction", isOn: Binding(
						get: { store.hexSettings.superEnabled },
						set: { store.send(.setSuperEnabled($0)) }
					))
					Text("Say \u{201C}legacy\u{201D} or \u{201C}Lucy\u{201D}, then what to do. With text selected, \u{201C}legacy, make this shorter\u{201D} rewrites the selection. With nothing selected, \u{201C}legacy, reply saying I\u{2019}m in for Thursday\u{201D} writes the reply at the cursor, using the text box as context. Works in any mode, with the AI below.")
						.settingsCaption()
				} icon: {
					Image(systemName: "sparkle")
				}
			} header: {
				Text("How your words are written")
			}

			if !store.state.isRewriteReady(.primary), store.hexSettings.rewriteMode.rewrites {
				Section {
					Label {
						Text("Choose an AI below to tidy your dictations. Until one is set up, your words are pasted exactly as heard.")
					} icon: {
						Image(systemName: "info.circle.fill").foregroundStyle(.orange)
					}
				}
			}

			RewriteProviderSection(store: store, role: .primary, title: "AI model")

			Section {
				Label {
					Toggle("Use a backup AI if the first one fails", isOn: Binding(
						get: { store.hexSettings.rewriteFallbackEnabled },
						set: { store.send(.setRewriteFallbackEnabled($0)) }
					))
					Text("If both fail or take too long, your words are pasted as heard. Nothing is lost.")
						.settingsCaption()
				} icon: {
					Image(systemName: "arrow.triangle.branch")
				}
			}

			if store.hexSettings.rewriteFallbackEnabled {
				RewriteProviderSection(store: store, role: .fallback, title: "Backup AI model")
			}

			Section {
				DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
					RewriteAdvancedOptions(store: store)
				}
			}

			if showsAdvanced {
				RewriteInstructionsSection(store: store)
			}
		}
		.formStyle(.grouped)
		.task { await store.send(.refreshLocalModels).finish() }
		.onAppear {
			vocabularyText = store.hexSettings.vocabulary.joined(separator: ", ")
		}
		.enableInjection()
	}

	static func terms(from text: String) -> [String] {
		text.components(separatedBy: CharacterSet(charactersIn: ",\n"))
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty }
	}
}

/// Shortcut and Prompt-mode toggles; most people never need them.
private struct RewriteAdvancedOptions: View {
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			option(
				"Switch modes with ⌃⌥1 / ⌃⌥2 / ⌃⌥3 / ⌃⌥4",
				isOn: store.hexSettings.rewriteModeShortcutsEnabled,
				set: { .setRewriteModeShortcutsEnabled($0) },
				caption: "Raw, Clean, Prompt, Notes, from any app. The menu bar icon shows R, P or N when the mode isn't Clean."
			)
			option(
				"Cycle modes with ⌃⌥",
				isOn: store.hexSettings.modeCyclerEnabled,
				set: { .setModeCyclerEnabled($0) },
				caption: "Hold ⌃ and press ⌥: a bar shows the modes. Press ⌥ again, or keep holding it, to move along; release ⌃ to switch. While holding the talk key, tap ⌃ to switch mid-dictation."
			)
			option(
				"Merge into the text already in the field",
				isOn: store.hexSettings.mergeIntoFieldEnabled,
				set: { .setMergeIntoFieldEnabled($0) },
				caption: "In Prompt mode, when the text box already holds a prompt, saying “add cheesecake” adds one more bullet to it. The merged text replaces the box, and ⌘Z undoes it. Terminals are skipped."
			)
			option(
				"Learn names from the text around the cursor",
				isOn: store.hexSettings.contextTermsEnabled,
				set: { .setContextTermsEnabled($0) },
				caption: "When you start talking, names and terms near the cursor (SwiftUI, Syncthing, CLAUDE.md) are read so the AI spells them the same way if you say them. Only the names go to the AI, not the text."
			)
			option(
				"Show Legacy while you speak",
				isOn: store.hexSettings.superEarlyDetection,
				set: { .setSuperEarlyDetection($0) },
				caption: "Apple Speech listens to the first 3 seconds on this Mac to spot \u{201C}legacy\u{201D}, so the indicator changes before you let go. Needs Apple Speech\u{2019}s English model; without it Legacy still works and shows once you let go."
			)
			option(
				"Code talk in Prompt mode",
				isOn: store.hexSettings.codeTalkEnabled,
				set: { .setCodeTalkEnabled($0) },
				caption: "Say “slash handoff” for /handoff, “claude dot md” for CLAUDE.md, “at readme dot md” for @README.md. Knows the skills and commands in ~/.claude."
			)
		}
		.padding(.top, 6)
	}

	private func option(_ title: String, isOn: Bool, set: @escaping (Bool) -> SettingsFeature.Action, caption: String) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			Toggle(title, isOn: Binding(get: { isOn }, set: { store.send(set($0)) }))
			Text(caption).settingsCaption()
		}
	}
}

/// One AI slot (primary or backup): pick a provider, then either download a model or paste a key.
private struct RewriteProviderSection: View {
	@Bindable var store: StoreOf<SettingsFeature>
	let role: RewriteEndpointRole
	let title: String

	private static let efforts = ["", "none", "minimal", "low", "medium", "high"]
	private static let cloudProviders: [RewriteProvider] = [.openAI, .anthropic, .gemini, .groq, .openRouter]

	private var endpoint: Binding<RewriteEndpoint> {
		Binding(
			get: { store.hexSettings.endpoint(for: role) },
			set: { store.send(.setRewriteEndpoint(role, $0)) }
		)
	}

	private var provider: RewriteProvider { endpoint.wrappedValue.provider }

	var body: some View {
		Section {
			Label {
				Picker("Use", selection: Binding(
					get: { provider },
					set: { store.send(.setRewriteProvider(role, $0)) }
				)) {
					Text(RewriteProvider.onDevice.displayName).tag(RewriteProvider.onDevice)
					Divider()
					ForEach(Self.cloudProviders, id: \.self) { provider in
						Text(provider.displayName).tag(provider)
					}
					Divider()
					Text(RewriteProvider.ollama.displayName).tag(RewriteProvider.ollama)
					Text(RewriteProvider.custom.displayName).tag(RewriteProvider.custom)
				}
				Text(provider.blurb).settingsCaption()
			} icon: {
				Image(systemName: provider.isCloud ? "cloud" : "desktopcomputer")
			}

			if provider == .onDevice {
				ForEach(LocalLLMModel.allCases) { model in
					LocalModelRow(store: store, role: role, model: model)
				}
				if let error = store.localModelError {
					Label(error, systemImage: "xmark.octagon.fill").settingsStatus(.red)
				}
			} else {
				connectionFields
			}

			Label {
				HStack(alignment: .firstTextBaseline) {
					Button(provider == .onDevice ? "Try it" : "Check connection") {
						store.send(provider == .onDevice ? .testRewriteEndpoint(role) : .connectRewriteEndpoint(role))
					}
					.disabled(provider == .onDevice && !store.state.isRewriteReady(role))
					statusView
					Spacer(minLength: 0)
				}
				Text(provider.isCloud
					? "Each dictation is sent to \(provider.displayName) to be rewritten."
					: "Your dictations never leave this Mac.")
					.settingsCaption()
			} icon: {
				Image(systemName: "checkmark.seal")
			}

			DisclosureGroup("Fine-tuning") {
				if provider != .onDevice, provider != .anthropic {
					Picker("Reasoning effort", selection: endpoint.reasoningEffort) {
						ForEach(Self.efforts, id: \.self) { effort in
							Text(effort.isEmpty ? "Model default" : effort).tag(effort)
						}
					}
				}
				Stepper(
					"Give up after \(Int(endpoint.wrappedValue.timeout)) s",
					value: endpoint.timeout,
					in: 1...60,
					step: 1
				)
			}
		} header: {
			Text(title)
		}
	}

	@ViewBuilder
	private var connectionFields: some View {
		if !provider.hasFixedAddress {
			Label {
				TextField("Address", text: endpoint.baseURL, prompt: Text(provider == .ollama ? "http://localhost:11434/v1" : "https://host:20128/v1"))
			} icon: {
				Image(systemName: "network")
			}
		}

		if provider != .ollama {
			Label {
				SecureField("API key", text: Binding(
					get: { store.state.apiKey(for: role) },
					set: { store.send(.setRewriteAPIKey(role, $0)) }
				), prompt: Text(provider.needsAPIKey ? "Paste your key" : "Optional"))
				HStack {
					Text("Kept in your Mac's Keychain.").settingsCaption()
					Spacer()
					if let url = provider.keyPageURL {
						Link("Get a key", destination: url).font(.caption)
					}
				}
			} icon: {
				Image(systemName: "key")
			}
		}

		Label {
			TextField("Model", text: endpoint.model, prompt: Text(provider.defaultModel.isEmpty ? "Model ID" : provider.defaultModel))
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
			if provider.needsAPIKey {
				Text("Check connection picks a fast model for you.").settingsCaption()
			}
		} icon: {
			Image(systemName: "cpu")
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

/// A downloadable on-device model: download with progress, pick it, or delete it.
private struct LocalModelRow: View {
	@Bindable var store: StoreOf<SettingsFeature>
	let role: RewriteEndpointRole
	let model: LocalLLMModel
	@State private var machine: MachineProbe?

	/// A model already downloaded stays usable; only a download is checked against this Mac.
	private var fit: ModelFit.Verdict { isDownloaded ? .fits : model.fit(on: machine) }
	private var isDownloaded: Bool { store.localModelsDownloaded.contains(model) }
	private var isSelected: Bool { store.hexSettings.endpoint(for: role).model == model.repository }

	var body: some View {
		HStack(alignment: .top, spacing: 10) {
			Image(systemName: isSelected && isDownloaded ? "checkmark.circle.fill" : "circle")
				.foregroundStyle(isSelected && isDownloaded ? Color.accentColor : .secondary)
				.padding(.top, 2)
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 6) {
					Text(model.displayName)
					if fit.reason != nil {
						WontFitBadge()
					} else if model == .recommended {
						Text("Recommended")
							.font(.caption2)
							.padding(.horizontal, 5)
							.padding(.vertical, 1)
							.background(Capsule().fill(Color.accentColor.opacity(0.15)))
					}
				}
				Text("\(model.downloadSize). \(model.summary)").settingsCaption()
				if let progress = store.localModelProgress[model] {
					ProgressView(value: progress)
						.progressViewStyle(.linear)
						.frame(maxWidth: 260)
				}
			}
			Spacer()
			if let reason = fit.reason {
				WontFitInfoButton(reason: reason)
			}
			if store.localModelProgress[model] != nil {
				Button("Cancel") { store.send(.cancelLocalModelDownload(model)) }
			} else if isDownloaded {
				if !isSelected {
					Button("Use") { select() }
				}
				Menu {
					Button("Delete Download", role: .destructive) { store.send(.deleteLocalModel(model)) }
				} label: {
					Image(systemName: "ellipsis.circle")
				}
				.menuStyle(.borderlessButton)
				.fixedSize()
			} else {
				Button("Download") { store.send(.downloadLocalModel(model)) }
					.buttonStyle(.borderedProminent)
					.disabled(fit.reason != nil)
					.help(fit.reason ?? "")
			}
		}
		.opacity(fit.reason != nil ? 0.55 : 1)
		.onAppear { machine = MachineProbe.current() }
		.contentShape(Rectangle())
		.onTapGesture { if isDownloaded { select() } }
	}

	private func select() {
		var endpoint = store.hexSettings.endpoint(for: role)
		endpoint.model = model.repository
		store.send(.setRewriteEndpoint(role, endpoint))
	}
}

/// Lets the user replace each mode's built-in instructions; blank or unchanged text keeps the default.
private struct RewriteInstructionsSection: View {
	@Bindable var store: StoreOf<SettingsFeature>
	@State private var mode: RewriteMode = .prompt
	@State private var text = ""

	private static let editableModes = RewriteMode.allCases.filter(\.rewrites)

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
				Text("Replaces what the model is told to do in this mode. LegacyScribe always adds four rules: treat the dictation as text to rewrite, fix misheard terms, use your vocabulary, and output only the rewrite.")
					.settingsCaption()
			} icon: {
				Image(systemName: "text.badge.star")
			}
		} header: {
			Text("Instructions")
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

private extension View {
	func settingsStatus(_ color: Color) -> some View {
		self.font(.caption)
			.foregroundStyle(color)
			.lineLimit(3)
			.textSelection(.enabled)
	}
}
