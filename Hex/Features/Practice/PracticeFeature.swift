import ComposableArchitecture
import Foundation
import HexCore

/// The Practice tab: what dictations became when sent, vocabulary suggestions from history (only when
/// asked), and a research question about personalizing the models, answered through OmniRoute.
@Reducer
struct PracticeFeature {
	@ObservableState
	struct State: Equatable {
		@Shared(.hexSettings) var hexSettings: HexSettings
		@Shared(.sentEdits) var sentEdits: SentEditLog
		@Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory

		/// Nil until the user asks for a check.
		var suggestions: [VocabularySuggestion]?
		var isCheckingHistory = false
		var checkError: String?
		/// Which model answered the last check.
		var checkedWith: String?

		var research = ""
		var isResearching = false
		var researchError: String?
	}

	enum Action {
		case checkHistory
		case suggestionsLoaded([VocabularySuggestion], model: String)
		case checkFailed(String)
		case addSuggestion(VocabularySuggestion)
		case dismissSuggestion(VocabularySuggestion)
		case setCaptureSentEdits(Bool)
		case setResearchModel(String)
		case askResearch
		case researchProgress(String)
		case researchFinished
		case researchFailed(String)
		case cancelResearch
	}

	enum CancelID {
		case check
		case research
	}

	/// A history check sends up to ~14K characters; a fast model answers in a few seconds.
	static let checkTimeout: Double = 45
	/// Search models read several pages before answering.
	static let researchTimeout: Double = 240

	@Dependency(\.rewrite) var rewrite
	@Dependency(\.keychain) var keychain

	var body: some ReducerOf<Self> {
		Reduce { state, action in
			switch action {
			case .checkHistory:
				let pairs = VocabularySuggester.pairs(
					history: state.transcriptionHistory.history,
					sentEdits: state.sentEdits.edits
				)
				state.checkError = nil
				guard !pairs.isEmpty else {
					state.suggestions = []
					state.checkError = "Nothing to check yet: no dictation has been rewritten or edited."
					return .none
				}
				state.isCheckingHistory = true
				let settings = state.hexSettings
				let messages = VocabularySuggester.messages(pairs: pairs, vocabulary: settings.vocabulary)
				var endpoints: [(RewriteEndpointRole, RewriteEndpoint)] = [(.primary, settings.rewritePrimary)]
				if settings.rewriteFallbackEnabled {
					endpoints.append((.fallback, settings.rewriteFallback))
				}
				return .run { [rewrite, keychain] send in
					var failures: [String] = []
					for (role, endpoint) in endpoints where endpoint.isConfigured {
						var endpoint = endpoint
						endpoint.timeout = max(endpoint.timeout, Self.checkTimeout)
						do {
							let answer = try await rewrite.complete(endpoint, keychain.read(role.keychainAccount), messages)
							if let suggestions = VocabularySuggester.parse(answer, vocabulary: settings.vocabulary) {
								await send(.suggestionsLoaded(suggestions, model: endpoint.model))
								return
							}
							failures.append("\(endpoint.model): the answer wasn't a list")
						} catch {
							failures.append("\(endpoint.model): \(error.localizedDescription)")
						}
					}
					await send(.checkFailed(failures.joined(separator: "\n")))
				}
				.cancellable(id: CancelID.check, cancelInFlight: true)

			case let .suggestionsLoaded(suggestions, model):
				state.isCheckingHistory = false
				state.suggestions = suggestions
				state.checkedWith = model
				HexLog.learning.info("History check by \(model, privacy: .public): \(suggestions.count) suggestions")
				return .none

			case let .checkFailed(message):
				state.isCheckingHistory = false
				state.checkError = message
				return .none

			case let .addSuggestion(suggestion):
				state.$hexSettings.withLock { settings in
					if !settings.vocabulary.contains(where: { $0.caseInsensitiveCompare(suggestion.term) == .orderedSame }) {
						settings.vocabulary.append(suggestion.term)
					}
				}
				state.suggestions?.removeAll { $0.id == suggestion.id }
				return .none

			case let .dismissSuggestion(suggestion):
				state.suggestions?.removeAll { $0.id == suggestion.id }
				return .none

			case let .setCaptureSentEdits(enabled):
				state.$hexSettings.withLock { $0.captureSentEdits = enabled }
				return .none

			case let .setResearchModel(model):
				state.$hexSettings.withLock { $0.practiceResearchModel = model }
				return .none

			case .askResearch:
				let settings = state.hexSettings
				let model = settings.practiceResearchModel.trimmingCharacters(in: .whitespaces)
				var endpoint = settings.rewritePrimary
				endpoint.model = model.isEmpty ? endpoint.model : model
				endpoint.timeout = Self.researchTimeout
				endpoint.reasoningEffort = ""
				let edits = state.sentEdits.edits
				let messages = PracticeResearch.messages(.init(
					dictations: state.transcriptionHistory.history.count,
					sentEdits: edits.count,
					editedSentEdits: edits.filter(\.wasEdited).count,
					engine: settings.selectedModel
				))
				state.research = ""
				state.researchError = nil
				state.isResearching = true
				return .run { [rewrite, keychain] send in
					do {
						for try await text in rewrite.stream(endpoint, keychain.read(RewriteEndpointRole.primary.keychainAccount), messages) {
							await send(.researchProgress(text))
						}
						await send(.researchFinished)
					} catch is CancellationError {
						await send(.researchFinished)
					} catch {
						await send(.researchFailed("\(endpoint.model): \(error.localizedDescription)"))
					}
				}
				.cancellable(id: CancelID.research, cancelInFlight: true)

			case let .researchProgress(text):
				state.research = text
				return .none

			case .researchFinished:
				state.isResearching = false
				if state.research.isEmpty {
					state.researchError = "The model returned no text."
				}
				return .none

			case let .researchFailed(message):
				state.isResearching = false
				state.researchError = message
				return .none

			case .cancelResearch:
				state.isResearching = false
				return .cancel(id: CancelID.research)
			}
		}
	}
}
