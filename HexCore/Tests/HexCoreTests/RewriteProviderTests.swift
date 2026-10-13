import Foundation
@testable import HexCore
import Testing

struct RewriteProviderTests {
	@Test
	func endpointsSavedBeforeProvidersGetOneFromTheAddress() throws {
		let json = #"""
		{"rewritePrimary":{"baseURL":"http://localhost:20128/v1","model":"groq/openai/gpt-oss-120b"},
		 "rewriteFallback":{"baseURL":"http://localhost:11434/v1","model":"qwen3:8b"}}
		"""#
		let settings = try JSONDecoder().decode(HexSettings.self, from: Data(json.utf8))
		#expect(settings.rewritePrimary.provider == .custom)
		#expect(settings.rewritePrimary.resolvedBaseURL == "http://localhost:20128/v1")
		#expect(settings.rewriteFallback.provider == .ollama)
		#expect(RewriteProvider.inferred(fromBaseURL: "https://api.openai.com/v1") == .openAI)
		#expect(RewriteProvider.inferred(fromBaseURL: "https://api.groq.com/openai/v1") == .groq)
	}

	@Test
	func hostedProvidersIgnoreAStoredAddress() {
		var endpoint = RewriteEndpoint.preset(.anthropic)
		endpoint.baseURL = "http://stale/v1"
		#expect(endpoint.resolvedBaseURL == "https://api.anthropic.com/v1")
		#expect(endpoint.isConfigured)
		#expect(RewriteEndpoint.preset(.custom).isConfigured == false)
	}

	@Test
	func hostedKeysAreKeptPerProviderAndCustomKeysPerSlot() {
		#expect(RewriteEndpoint.preset(.openAI).keychainAccount(.primary) == "apiKey.openAI")
		#expect(RewriteEndpoint.preset(.openAI).keychainAccount(.fallback) == "apiKey.openAI")
		// The account custom endpoints used before providers existed, so an OmniRoute key survives.
		#expect(RewriteEndpoint(baseURL: "http://omni/v1", model: "m").keychainAccount(.primary) == "apiKey.primary")
	}

	@Test
	func picksAPreferredModelFromTheListing() {
		#expect(RewriteProvider.openAI.preferredModel(from: ["gpt-4o", "gpt-5-mini", "gpt-5-nano"]) == "gpt-5-nano")
		#expect(RewriteProvider.gemini.preferredModel(from: ["models/gemini-2.5-pro", "models/gemini-3.1-flash-lite"]) == "gemini-3.1-flash-lite")
		// No preferred ID offered: the newest fast-looking one.
		#expect(RewriteProvider.anthropic.preferredModel(from: ["claude-opus-9", "claude-haiku-7", "claude-haiku-6"]) == "claude-haiku-7")
		#expect(RewriteProvider.custom.preferredModel(from: ["a", "b"]) == nil)
	}

	@Test
	func notesWriterDefaultsToOllamaForExistingSettings() throws {
		let old = try JSONDecoder().decode(HexSettings.self, from: Data(#"{"notesModel":"qwen3:8b"}"#.utf8))
		#expect(old.notesWriter == .ollama)
		let fresh = try JSONDecoder().decode(HexSettings.self, from: Data("{}".utf8))
		#expect(fresh.notesWriter == .onDevice)
		#expect(fresh.voiceIsolationEnabled == false)
	}
}

struct AnthropicMessagesAPITests {
	@Test
	func systemPromptIsATopLevelField() throws {
		let request = try AnthropicMessagesAPI.messagesRequest(
			baseURL: "https://api.anthropic.com/v1",
			apiKey: "sk-ant",
			model: "claude-haiku-5-5",
			messages: [ChatMessage(role: "system", content: "Rewrite."), ChatMessage(role: "user", content: "hi")],
			timeout: 5
		)
		#expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
		#expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
		#expect(request.value(forHTTPHeaderField: "anthropic-version") == AnthropicMessagesAPI.version)
		let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
		#expect(body["system"] as? String == "Rewrite.")
		let messages = try #require(body["messages"] as? [[String: Any]])
		#expect(messages.count == 1)
		#expect(messages[0]["role"] as? String == "user")
	}

	@Test
	func parsesTextAndRejectsACutOffAnswer() throws {
		let ok = #"{"content":[{"type":"text","text":"Hello."}],"stop_reason":"end_turn"}"#
		#expect(try AnthropicMessagesAPI.content(from: Data(ok.utf8)) == "Hello.")
		let cut = #"{"content":[{"type":"text","text":"Hel"}],"stop_reason":"max_tokens"}"#
		#expect(throws: ChatCompletionAPI.Failure.truncated) { try AnthropicMessagesAPI.content(from: Data(cut.utf8)) }
	}
}

struct OpenAIRequestShapeTests {
	@Test
	func openAIGetsItsOwnFieldsAndOthersKeepTheClassicOnes() throws {
		func body(_ provider: RewriteProvider) throws -> [String: Any] {
			var request = ChatCompletionAPI.Request(model: "m", messages: [.init(role: "user", content: "hi")], reasoningEffort: "low")
			request.adapt(for: provider)
			return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
		}
		let openAI = try body(.openAI)
		#expect(openAI["temperature"] == nil)
		#expect(openAI["max_tokens"] == nil)
		#expect(openAI["max_completion_tokens"] as? Int == ChatCompletionAPI.defaultMaxTokens)
		#expect(openAI["reasoning_effort"] as? String == "low")
		let groq = try body(.groq)
		#expect(groq["temperature"] as? Double == 0.2)
		#expect(groq["max_tokens"] as? Int == ChatCompletionAPI.defaultMaxTokens)
	}
}
