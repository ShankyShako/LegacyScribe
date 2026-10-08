import Foundation

/// One OpenAI-compatible chat endpoint and the model to call on it.
public struct RewriteEndpoint: Codable, Equatable, Sendable {
	/// API root, e.g. `https://host:20128/v1`.
	public var baseURL: String
	public var model: String
	/// Sent as `reasoning_effort` when non-empty.
	public var reasoningEffort: String
	/// Seconds before giving up on this endpoint.
	public var timeout: Double

	public init(baseURL: String, model: String, reasoningEffort: String = "", timeout: Double = 5) {
		self.baseURL = baseURL
		self.model = model
		self.reasoningEffort = reasoningEffort
		self.timeout = timeout
	}

	/// Missing fields take defaults: one bad endpoint must not make the whole settings file undecodable.
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
		model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
		reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? ""
		timeout = try container.decodeIfPresent(Double.self, forKey: .timeout) ?? 5
	}

	public var isConfigured: Bool {
		!baseURL.trimmingCharacters(in: .whitespaces).isEmpty && !model.trimmingCharacters(in: .whitespaces).isEmpty
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
}

/// Tries each endpoint in turn and never loses the dictation: if all of them fail,
/// the outcome carries the transcript unchanged.
public enum RewriteChain {
	public typealias Complete = @Sendable (RewriteEndpointRole, RewriteEndpoint, [ChatMessage]) async throws -> String

	public static func run(
		transcript: String,
		mode: RewriteMode,
		vocabulary: [String],
		targetAppName: String?,
		instructions: String? = nil,
		endpoints: [(RewriteEndpointRole, RewriteEndpoint)],
		complete: Complete
	) async -> RewriteOutcome {
		var outcome = RewriteOutcome(text: transcript, rewrittenBy: nil, failures: [])
		guard let messages = RewritePromptBuilder.messages(
			mode: mode,
			transcript: transcript,
			vocabulary: vocabulary,
			targetAppName: targetAppName,
			instructions: instructions
		) else { return outcome }

		for (role, endpoint) in endpoints where endpoint.isConfigured {
			if Task.isCancelled { break }
			do {
				let output = RewriteOutputSanitizer.sanitize(try await complete(role, endpoint, messages))
				if let problem = rejection(of: output, transcript: transcript) {
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
	static func rejection(of output: String, transcript: String) -> String? {
		if output.isEmpty { return "empty rewrite" }
		if output.count > transcript.count * 4 + 400 {
			return "rewrite is \(output.count) characters for a \(transcript.count)-character dictation"
		}
		return nil
	}
}
