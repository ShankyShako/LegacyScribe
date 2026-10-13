import Foundation

/// Request building and response parsing for Anthropic's `/v1/messages`. The system prompt is a top-level
/// field there, not a message, and the key goes in `x-api-key`. Transport lives in the app.
public enum AnthropicMessagesAPI {
	public static let version = "2023-06-01"

	struct Body: Encodable {
		struct Message: Encodable {
			var role: String
			var content: String
		}

		var model: String
		var system: String?
		var messages: [Message]
		var max_tokens: Int
		var temperature: Double
	}

	public static func messagesRequest(
		baseURL: String,
		apiKey: String?,
		model: String,
		messages: [ChatMessage],
		maxTokens: Int = ChatCompletionAPI.defaultMaxTokens,
		temperature: Double = 0.2,
		timeout: TimeInterval
	) throws -> URLRequest {
		let system = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
		let body = Body(
			model: model,
			system: system.isEmpty ? nil : system,
			messages: messages.filter { $0.role != "system" }.map { Body.Message(role: $0.role, content: $0.content) },
			max_tokens: maxTokens,
			temperature: temperature
		)
		var request = URLRequest(url: try ChatCompletionAPI.endpoint(baseURL, path: "messages"), timeoutInterval: timeout)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		authorize(&request, apiKey: apiKey)
		request.httpBody = try JSONEncoder().encode(body)
		return request
	}

	/// `/v1/models` answers in the same `{"data": [{"id": …}]}` shape as OpenAI's, so
	/// `ChatCompletionAPI.modelIDs(from:)` parses it.
	public static func modelsRequest(baseURL: String, apiKey: String?, timeout: TimeInterval = 10) throws -> URLRequest {
		var request = URLRequest(url: try ChatCompletionAPI.endpoint(baseURL, path: "models"), timeoutInterval: timeout)
		authorize(&request, apiKey: apiKey)
		return request
	}

	static func authorize(_ request: inout URLRequest, apiKey: String?) {
		request.setValue(version, forHTTPHeaderField: "anthropic-version")
		if let apiKey, !apiKey.isEmpty {
			request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
		}
	}

	public static func content(from data: Data) throws -> String {
		struct Response: Decodable {
			struct Block: Decodable {
				var type: String
				var text: String?
			}
			var content: [Block]
			var stop_reason: String?
		}
		let response = try JSONDecoder().decode(Response.self, from: data)
		if response.stop_reason == "max_tokens" { throw ChatCompletionAPI.Failure.truncated }
		let text = response.content.filter { $0.type == "text" }.compactMap(\.text).joined()
		guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw ChatCompletionAPI.Failure.emptyResponse
		}
		return text
	}
}
