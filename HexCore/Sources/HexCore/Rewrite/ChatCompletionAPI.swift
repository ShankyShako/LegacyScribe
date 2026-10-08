import Foundation

/// Request building and response parsing for OpenAI-compatible `/chat/completions` and `/models`
/// endpoints (OmniRoute, OpenAI, Ollama, Groq, Gemini's OpenAI shim). Transport lives in the app.
public enum ChatCompletionAPI {
	public static let defaultMaxTokens = 4096

	public struct Request: Encodable, Equatable, Sendable {
		public var model: String
		public var messages: [ChatMessage]
		public var temperature: Double
		public var maxTokens: Int
		/// Omitted from the body when nil; not every model accepts it.
		public var reasoningEffort: String?
		public var stream: Bool = false

		public init(model: String, messages: [ChatMessage], temperature: Double = 0.2, maxTokens: Int = ChatCompletionAPI.defaultMaxTokens, reasoningEffort: String? = nil) {
			self.model = model
			self.messages = messages
			self.temperature = temperature
			self.maxTokens = maxTokens
			self.reasoningEffort = reasoningEffort
		}

		enum CodingKeys: String, CodingKey {
			case model, messages, temperature, stream
			case maxTokens = "max_tokens"
			case reasoningEffort = "reasoning_effort"
		}
	}

	public enum Failure: Error, Equatable, LocalizedError {
		case invalidBaseURL(String)
		case http(status: Int, body: String)
		case emptyResponse
		/// The model hit its token limit; the text is cut off, so it must not be pasted.
		case truncated

		public var errorDescription: String? {
			switch self {
			case let .invalidBaseURL(url): "Invalid base URL: \(url)"
			case let .http(status, body): "HTTP \(status): \(body.prefix(200))"
			case .emptyResponse: "The model returned no text"
			case .truncated: "The model's answer was cut off at its token limit"
			}
		}
	}

	/// `base` is the API root, e.g. `https://host:20128/v1`.
	public static func endpoint(_ base: String, path: String) throws -> URL {
		let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
		guard var components = URLComponents(string: trimmed),
		      let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
		      components.host?.isEmpty == false
		else { throw Failure.invalidBaseURL(base) }
		while components.path.hasSuffix("/") { components.path.removeLast() }
		components.path += "/" + path
		guard let url = components.url else { throw Failure.invalidBaseURL(base) }
		return url
	}

	public static func chatRequest(baseURL: String, apiKey: String?, body: Request, timeout: TimeInterval) throws -> URLRequest {
		var request = URLRequest(url: try endpoint(baseURL, path: "chat/completions"), timeoutInterval: timeout)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		authorize(&request, apiKey: apiKey)
		request.httpBody = try JSONEncoder().encode(body)
		return request
	}

	public static func modelsRequest(baseURL: String, apiKey: String?, timeout: TimeInterval = 10) throws -> URLRequest {
		var request = URLRequest(url: try endpoint(baseURL, path: "models"), timeoutInterval: timeout)
		authorize(&request, apiKey: apiKey)
		return request
	}

	static func authorize(_ request: inout URLRequest, apiKey: String?) {
		if let apiKey, !apiKey.isEmpty {
			request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
		}
	}

	public static func checkStatus(_ status: Int, data: Data) throws {
		guard (200..<300).contains(status) else {
			throw Failure.http(status: status, body: String(decoding: data, as: UTF8.self))
		}
	}

	public static func content(from data: Data) throws -> String {
		struct Response: Decodable {
			struct Choice: Decodable {
				struct Message: Decodable { var content: String? }
				var message: Message?
				var finish_reason: String?
			}
			var choices: [Choice]
		}
		let response = try JSONDecoder().decode(Response.self, from: data)
		guard let choice = response.choices.first else { throw Failure.emptyResponse }
		if choice.finish_reason == "length" { throw Failure.truncated }
		guard let content = choice.message?.content,
		      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		else { throw Failure.emptyResponse }
		return content
	}

	/// One server-sent-events line of a streamed completion.
	public enum StreamEvent: Equatable, Sendable {
		case delta(String)
		case finished(reason: String)
		case done
	}

	/// Parses a `stream: true` line (`data: {...}` or `data: [DONE]`); nil for blank lines, comments and
	/// chunks with no text (role announcements, reasoning-only deltas).
	public static func streamEvent(fromLine line: String) -> StreamEvent? {
		guard line.hasPrefix("data:") else { return nil }
		let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
		if payload == "[DONE]" { return .done }
		struct Chunk: Decodable {
			struct Choice: Decodable {
				struct Delta: Decodable { var content: String? }
				var delta: Delta?
				var finish_reason: String?
			}
			var choices: [Choice]
		}
		guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)),
		      let choice = chunk.choices.first
		else { return nil }
		if let text = choice.delta?.content, !text.isEmpty { return .delta(text) }
		if let reason = choice.finish_reason { return .finished(reason: reason) }
		return nil
	}

	public static func modelIDs(from data: Data) throws -> [String] {
		struct Response: Decodable {
			struct Entry: Decodable { var id: String }
			var data: [Entry]
		}
		return try JSONDecoder().decode(Response.self, from: data).data.map(\.id).sorted()
	}
}
