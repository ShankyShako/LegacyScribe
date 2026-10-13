import Foundation

/// One rewrite endpoint: a provider and the model to call on it.
public struct RewriteEndpoint: Codable, Equatable, Sendable {
	public var provider: RewriteProvider
	/// API root for Ollama and custom servers, e.g. `https://host:20128/v1`; hosted providers use their own
	/// (`resolvedBaseURL`).
	public var baseURL: String
	/// A model ID, or a `LocalLLMModel` repository for on-device.
	public var model: String
	/// Sent as `reasoning_effort` when non-empty.
	public var reasoningEffort: String
	/// Seconds before giving up on this endpoint.
	public var timeout: Double

	public init(provider: RewriteProvider? = nil, baseURL: String, model: String, reasoningEffort: String = "", timeout: Double = 5) {
		self.provider = provider ?? RewriteProvider.inferred(fromBaseURL: baseURL)
		self.baseURL = baseURL
		self.model = model
		self.reasoningEffort = reasoningEffort
		self.timeout = timeout
	}

	/// Missing fields take defaults: one bad endpoint must not make the whole settings file undecodable.
	/// Endpoints saved before providers existed get theirs from the address.
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
		model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
		reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? ""
		timeout = try container.decodeIfPresent(Double.self, forKey: .timeout) ?? 5
		provider = (try? container.decodeIfPresent(RewriteProvider.self, forKey: .provider))
			?? RewriteProvider.inferred(fromBaseURL: baseURL)
	}

	/// Has what it needs apart from an API key (which lives in the Keychain).
	public var isConfigured: Bool {
		let hasModel = !model.trimmingCharacters(in: .whitespaces).isEmpty
		return hasModel && (provider.hasFixedAddress || !baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
	}
}

/// Which slot an endpoint fills; also names its API key in the Keychain.
public enum RewriteEndpointRole: String, CaseIterable, Equatable, Sendable {
	case primary
	case fallback
}

public struct RewriteOutcome: Equatable, Sendable {
	/// What to paste: the rewrite, or the transcript unchanged when every endpoint failed.
	public var text: String
	/// Model that produced `text`; nil when the raw transcript is pasted.
	public var rewrittenBy: String?
	/// One line per endpoint that failed, in order tried.
	public var failures: [String]

	public init(text: String, rewrittenBy: String?, failures: [String]) {
		self.text = text
		self.rewrittenBy = rewrittenBy
		self.failures = failures
	}
}

/// Tries each endpoint in turn and never loses the dictation: if all of them fail,
/// the outcome carries the transcript unchanged.
public enum RewriteChain {
	public typealias Complete = @Sendable (RewriteEndpointRole, RewriteEndpoint, [ChatMessage]) async throws -> String

	public static func run(
		transcript: String,
		mode: RewriteMode,
		vocabulary: [String],
		nearbyTerms: [String] = [],
		targetAppName: String?,
		instructions: String? = nil,
		codeTalkCommands: [String]? = nil,
		existingText: String? = nil,
		endpoints: [(RewriteEndpointRole, RewriteEndpoint)],
		complete: Complete
	) async -> RewriteOutcome {
		guard let messages = RewritePromptBuilder.messages(
			mode: mode,
			transcript: transcript,
			vocabulary: vocabulary,
			nearbyTerms: nearbyTerms,
			targetAppName: targetAppName,
			instructions: instructions,
			codeTalkCommands: codeTalkCommands,
			existingText: existingText
		) else { return RewriteOutcome(text: transcript, rewrittenBy: nil, failures: []) }
		return await run(messages: messages, original: transcript, endpoints: endpoints, complete: complete) {
			rejection(of: $0, transcript: transcript, existingText: existingText)
		}
	}

	/// Sends `messages` to each endpoint in turn until one answers with text `rejection` accepts (nil);
	/// the outcome carries `original` when none does.
	public static func run(
		messages: [ChatMessage],
		original: String,
		endpoints: [(RewriteEndpointRole, RewriteEndpoint)],
		complete: Complete,
		rejection: (String) -> String?
	) async -> RewriteOutcome {
		var outcome = RewriteOutcome(text: original, rewrittenBy: nil, failures: [])
		for (role, endpoint) in endpoints where endpoint.isConfigured {
			if Task.isCancelled { break }
			do {
				let output = RewriteOutputSanitizer.sanitize(try await complete(role, endpoint, messages))
				if let problem = rejection(output) {
					outcome.failures.append("\(role.rawValue) \(endpoint.model): \(problem)")
					continue
				}
				outcome.text = output
				outcome.rewrittenBy = endpoint.model
				return outcome
			} catch {
				outcome.failures.append("\(role.rawValue) \(endpoint.model): \(error.localizedDescription)")
			}
		}
		return outcome
	}

	/// A rewrite far longer than the dictation means the model answered it instead of rewriting it.
	/// A merge must also keep the field's existing text.
	public static func rejection(of output: String, transcript: String, existingText: String? = nil) -> String? {
		if output.isEmpty { return "empty rewrite" }
		let budget = transcript.count * 4 + 400 + (existingText?.count ?? 0)
		if output.count > budget {
			return "rewrite is \(output.count) characters for a \(transcript.count)-character dictation"
		}
		if let existingText {
			return FieldMerge.rejection(of: output, existing: existingText)
		}
		return nil
	}
}
