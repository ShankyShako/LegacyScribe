import Foundation

/// Where a rewrite runs. Hosted providers need only an API key: their address is fixed here, and the model
/// is picked from what the key can reach (`preferredModel(from:)`). `custom` takes any OpenAI-compatible
/// address (OmniRoute, LM Studio, a company proxy).
public enum RewriteProvider: String, Codable, CaseIterable, Equatable, Sendable {
	/// A downloaded model run in-process with MLX (`LocalLLMModel`). No network, no key.
	case onDevice
	case openAI
	case anthropic
	case gemini
	case groq
	case openRouter
	/// Ollama on this Mac.
	case ollama
	/// Any OpenAI-compatible endpoint.
	case custom

	/// How requests are shaped.
	public enum Wire: Equatable, Sendable {
		/// `/chat/completions` (`ChatCompletionAPI`).
		case openAI
		/// `/v1/messages` (`AnthropicMessagesAPI`).
		case anthropic
		/// In-process MLX; the endpoint's model is a `LocalLLMModel` repository.
		case onDevice
	}

	public var wire: Wire {
		switch self {
		case .onDevice: .onDevice
		case .anthropic: .anthropic
		default: .openAI
		}
	}

	public var displayName: String {
		switch self {
		case .onDevice: "On this Mac"
		case .openAI: "OpenAI"
		case .anthropic: "Anthropic (Claude)"
		case .gemini: "Google Gemini"
		case .groq: "Groq"
		case .openRouter: "OpenRouter"
		case .ollama: "Ollama"
		case .custom: "Custom server"
		}
	}

	/// One line for the provider picker.
	public var blurb: String {
		switch self {
		case .onDevice: "Free and private: a model downloaded once runs on your Mac. Nothing leaves it."
		case .openAI: "Paste an API key from platform.openai.com."
		case .anthropic: "Paste an API key from console.anthropic.com."
		case .gemini: "Paste an API key from Google AI Studio. Has a free tier."
		case .groq: "Paste an API key from console.groq.com. Very fast, has a free tier."
		case .openRouter: "One key for many models, from openrouter.ai."
		case .ollama: "Uses models you run with Ollama on this Mac."
		case .custom: "Any OpenAI-compatible address, such as OmniRoute or LM Studio."
		}
	}

	/// Fixed for hosted providers; the starting value for Ollama and custom servers.
	public var defaultBaseURL: String {
		switch self {
		case .onDevice, .custom: ""
		case .openAI: "https://api.openai.com/v1"
		case .anthropic: "https://api.anthropic.com/v1"
		case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
		case .groq: "https://api.groq.com/openai/v1"
		case .openRouter: "https://openrouter.ai/api/v1"
		case .ollama: "http://localhost:11434/v1"
		}
	}

	/// The address can't be changed (hosted providers and on-device).
	public var hasFixedAddress: Bool {
		switch self {
		case .ollama, .custom: false
		default: true
		}
	}

	public var needsAPIKey: Bool {
		switch self {
		case .onDevice, .ollama, .custom: false
		default: true
		}
	}

	/// Sends the dictation off this Mac.
	public var isCloud: Bool {
		switch self {
		case .onDevice, .ollama: false
		default: true
		}
	}

	/// Where to create a key.
	public var keyPageURL: URL? {
		switch self {
		case .openAI: URL(string: "https://platform.openai.com/api-keys")
		case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
		case .gemini: URL(string: "https://aistudio.google.com/apikey")
		case .groq: URL(string: "https://console.groq.com/keys")
		case .openRouter: URL(string: "https://openrouter.ai/settings/keys")
		case .onDevice, .ollama, .custom: nil
		}
	}

	/// Fast models first: a rewrite has to land within a few seconds. Matched against the provider's own
	/// model list, so a renamed model falls through to the next one instead of failing.
	public var preferredModels: [String] {
		switch self {
		case .onDevice: [LocalLLMModel.recommended.repository]
		case .openAI: ["gpt-5.4-nano", "gpt-5-nano", "gpt-5.4-mini", "gpt-5-mini", "gpt-4.1-mini"]
		case .anthropic: ["claude-haiku-5-5", "claude-haiku-4-5"]
		case .gemini: ["gemini-3.1-flash-lite", "gemini-3.1-flash-lite-preview", "gemini-3-flash-preview", "gemini-2.5-flash-lite"]
		case .groq: ["openai/gpt-oss-120b", "openai/gpt-oss-20b", "llama-3.3-70b-versatile"]
		case .openRouter: ["openai/gpt-oss-120b", "openai/gpt-oss-20b"]
		case .ollama: ["qwen3:8b"]
		case .custom: []
		}
	}

	/// Words that mark a model as a small, fast one when none of `preferredModels` is offered.
	private var fastModelHints: [String] {
		switch self {
		case .openAI: ["nano", "mini"]
		case .anthropic: ["haiku"]
		case .gemini: ["flash-lite", "flash"]
		case .groq, .openRouter: ["gpt-oss", "instant"]
		default: []
		}
	}

	public var defaultModel: String { preferredModels.first ?? "" }

	/// Sent as `reasoning_effort`. Low keeps reasoning models from spending the time budget thinking;
	/// Gemini Flash-Lite truncated without "none" (2026-10-06).
	public var defaultReasoningEffort: String {
		switch self {
		case .openAI, .groq, .openRouter: "low"
		case .gemini: "none"
		case .ollama: "none"
		case .onDevice, .anthropic, .custom: ""
		}
	}

	/// Cloud calls answer in about a second; on-device generation runs at tens of tokens per second.
	public var defaultTimeout: Double {
		switch self {
		case .onDevice: 20
		case .ollama: 10
		default: 6
		}
	}

	/// The best model to use from `available` (a `/models` listing): the first preferred one offered,
	/// else the newest-looking fast one. Gemini lists IDs as `models/<id>`.
	public func preferredModel(from available: [String]) -> String? {
		let ids = available.map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
		if let match = preferredModels.first(where: ids.contains) { return match }
		for hint in fastModelHints {
			let matches = ids.filter { $0.contains(hint) && !$0.contains("preview") && !$0.contains("audio") && !$0.contains("tts") }
			if let newest = matches.sorted().last { return newest }
		}
		return nil
	}

	/// Settings written before providers existed only hold an address.
	public static func inferred(fromBaseURL baseURL: String) -> RewriteProvider {
		let host = URLComponents(string: baseURL.trimmingCharacters(in: .whitespaces))?.host?.lowercased() ?? ""
		let port = URLComponents(string: baseURL.trimmingCharacters(in: .whitespaces))?.port
		for provider in [RewriteProvider.openAI, .anthropic, .gemini, .groq, .openRouter] {
			if let fixedHost = URLComponents(string: provider.defaultBaseURL)?.host, host == fixedHost {
				return provider
			}
		}
		if port == 11434 { return .ollama }
		return .custom
	}
}

/// Models offered for on-device rewriting, downloaded from Hugging Face into
/// `<data root>/Models/mlx/<repository>` and run with mlx-swift-lm. All Apache-2.0.
public enum LocalLLMModel: String, CaseIterable, Identifiable, Sendable {
	case small = "mlx-community/Qwen3-1.7B-4bit"
	case balanced = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
	case large = "mlx-community/Qwen3-8B-4bit"

	public static let recommended = LocalLLMModel.balanced

	public var id: String { rawValue }
	public var repository: String { rawValue }

	public var displayName: String {
		switch self {
		case .small: "Small (Qwen3 1.7B)"
		case .balanced: "Balanced (Qwen3 4B)"
		case .large: "Large (Qwen3 8B)"
		}
	}

	public var downloadSize: String {
		switch self {
		case .small: "1 GB"
		case .balanced: "2.3 GB"
		case .large: "4.6 GB"
		}
	}

	public var summary: String {
		switch self {
		case .small: "Fastest, fine for tidying short dictations. For Macs with 8 GB of memory."
		case .balanced: "Recommended. Good cleanup and prompt structure on 16 GB Macs."
		case .large: "Best on-device quality, slower. Needs 24 GB of memory or more."
		}
	}

	/// Qwen3's hybrid models think before answering unless the chat template is told not to.
	public var hasThinkingSwitch: Bool { self != .balanced }

	/// Files to skip when downloading the repository.
	public static func isNeeded(_ path: String) -> Bool {
		!(path == "README.md" || path.hasPrefix(".") || path.contains("/"))
	}
}

extension RewriteEndpoint {
	/// A ready-to-use endpoint for `provider` with its defaults.
	public static func preset(_ provider: RewriteProvider) -> RewriteEndpoint {
		RewriteEndpoint(
			provider: provider,
			baseURL: provider.defaultBaseURL,
			model: provider.defaultModel,
			reasoningEffort: provider.defaultReasoningEffort,
			timeout: provider.defaultTimeout
		)
	}

	/// The address requests go to: fixed for hosted providers, as entered for Ollama and custom servers.
	public var resolvedBaseURL: String {
		provider.hasFixedAddress ? provider.defaultBaseURL : baseURL
	}

	/// Keychain account of this endpoint's API key. Hosted providers keep one key each, so switching
	/// provider and back doesn't lose it; custom servers keep theirs per slot, as before providers existed.
	public func keychainAccount(_ role: RewriteEndpointRole) -> String {
		provider.needsAPIKey ? "apiKey.\(provider.rawValue)" : "apiKey.\(role.rawValue)"
	}
}
