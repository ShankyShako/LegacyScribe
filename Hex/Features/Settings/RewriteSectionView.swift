import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

/// LLM rewrite: mode, primary and fallback endpoints, vocabulary.
struct RewriteSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	@State private var vocabularyText = ""

	var body: some View {
		Section {
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

			RewriteEndpointEditor(store: store, role: .primary, title: "Primary")

			Toggle("Fall back to a second endpoint", isOn: Binding(
				get: { store.hexSettings.rewriteFallbackEnabled },
				set: { store.send(.setRewriteFallbackEnabled($0)) }
			))
			if store.hexSettings.rewriteFallbackEnabled {
				RewriteEndpointEditor(store: store, role: .fallback, title: "Fallback")
			}
			Text("If every endpoint fails or times out, the transcript is pasted as recognized, so a dictation is never lost.")
				.settingsCaption()

			VStack(alignment: .leading, spacing: 4) {
				Text("Vocabulary")
				TextField("OmniRoute, Syncthing, LegacyScribe", text: $vocabularyText, axis: .vertical)
					.lineLimit(2...5)
					.onChange(of: vocabularyText) { _, text in
						store.send(.setVocabulary(Self.terms(from: text)))
					}
				Text("Names and jargon the rewrite should spell exactly. Separate with commas or new lines.")
					.settingsCaption()
			}
		} header: {
			Text("Rewrite")
		}
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

private struct RewriteEndpointEditor: View {
	@Bindable var store: StoreOf<SettingsFeature>
	let role: RewriteEndpointRole
	let title: String

	private static let efforts = ["", "none", "minimal", "low", "medium", "high"]

	private var endpoint: Binding<RewriteEndpoint> {
		Binding(
			get: { store.hexSettings.endpoint(for: role) },
			set: { store.send(.setRewriteEndpoint(role, $0)) }
		)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(title).font(.headline)

			TextField("Base URL", text: endpoint.baseURL, prompt: Text("https://host:20128/v1"))
				.textContentType(.URL)

			HStack {
				TextField("Model", text: endpoint.model, prompt: Text("groq/openai/gpt-oss-120b"))
				let options = store.rewriteModelOptions[role] ?? []
				Menu("Pick") {
					if options.isEmpty {
						Text("Press Load first")
					}
					ForEach(options, id: \.self) { model in
						Button(model) { endpoint.wrappedValue.model = model }
					}
				}
				.fixedSize()
				Button("Load") { store.send(.loadRewriteModels(role)) }
			}

			SecureField("API key", text: Binding(
				get: { store.rewriteAPIKeys[role] ?? "" },
				set: { store.send(.setRewriteAPIKey(role, $0)) }
			), prompt: Text("Optional; stored in the Keychain"))

			HStack {
				Picker("Reasoning", selection: endpoint.reasoningEffort) {
					ForEach(Self.efforts, id: \.self) { effort in
						Text(effort.isEmpty ? "Model default" : effort).tag(effort)
					}
				}
				.fixedSize()
				Spacer()
				Stepper(
					"Timeout \(Int(endpoint.wrappedValue.timeout)) s",
					value: endpoint.timeout,
					in: 1...60,
					step: 1
				)
				.fixedSize()
			}

			HStack(alignment: .firstTextBaseline) {
				Button("Test") { store.send(.testRewriteEndpoint(role)) }
				statusView
			}
		}
		.padding(.vertical, 4)
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
			.textSelection(.enabled)
			.fixedSize(horizontal: false, vertical: true)
	}
}
