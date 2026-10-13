import Dependencies
import DependenciesMacros
import Foundation
import HexCore

/// Runs the LLM rewrite step on whichever provider an endpoint names: OpenAI-compatible APIs (OpenAI, Gemini,
/// Groq, OpenRouter, Ollama, custom servers), Anthropic's Messages API, or the on-device model.
@DependencyClient
struct RewriteClient {
	/// One chat completion. Throws on HTTP errors, a cut-off answer, or when `endpoint.timeout` passes.
	var complete: @Sendable (_ endpoint: RewriteEndpoint, _ apiKey: String?, _ messages: [ChatMessage]) async throws -> String
	var listModels: @Sendable (_ endpoint: RewriteEndpoint, _ apiKey: String?) async throws -> [String]
	/// A streamed completion for long answers (OmniRoute cuts non-streamed calls at 30 s). Yields the text
	/// so far after each chunk; `endpoint.timeout` caps the whole call.
	var stream: @Sendable (_ endpoint: RewriteEndpoint, _ apiKey: String?, _ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> = { _, _, _ in
		AsyncThrowingStream { $0.finish() }
	}
}

extension RewriteClient: DependencyKey {
	static var liveValue: Self {
		let session: URLSession = {
			let configuration = URLSessionConfiguration.ephemeral
			// Groq sits behind Cloudflare, which rejects some default user agents (error 1010)
			// and OmniRoute passes ours through.
			let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
			configuration.httpAdditionalHeaders = ["User-Agent": "LegacyScribe/\(version)"]
			configuration.waitsForConnectivity = false
			return URLSession(configuration: configuration)
		}()

		@Sendable func fetch(_ request: URLRequest) async throws -> Data {
			let (data, response) = try await session.data(for: request)
			try ChatCompletionAPI.checkStatus((response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
			return data
		}

		@Sendable func openAICompletion(_ endpoint: RewriteEndpoint, _ apiKey: String?, _ messages: [ChatMessage], effort: String?) async throws -> String {
			var body = ChatCompletionAPI.Request(
				model: endpoint.model.trimmingCharacters(in: .whitespaces),
				messages: messages,
				reasoningEffort: effort
			)
			body.adapt(for: endpoint.provider)
			let request = try ChatCompletionAPI.chatRequest(
				baseURL: endpoint.resolvedBaseURL,
				apiKey: apiKey,
				body: body,
				timeout: endpoint.timeout
			)
			// URLRequest's timeout resets on every received packet; this caps the whole call.
			let data = try await withDeadline(seconds: endpoint.timeout) { try await fetch(request) }
			return try ChatCompletionAPI.content(from: data)
		}

		@Sendable func complete(_ endpoint: RewriteEndpoint, _ apiKey: String?, _ messages: [ChatMessage]) async throws -> String {
			switch endpoint.provider.wire {
			case .onDevice:
				return try await withDeadline(seconds: endpoint.timeout) {
					try await LocalLLM.shared.complete(repository: endpoint.model, messages: messages)
				}
			case .anthropic:
				let request = try AnthropicMessagesAPI.messagesRequest(
					baseURL: endpoint.resolvedBaseURL,
					apiKey: apiKey,
					model: endpoint.model.trimmingCharacters(in: .whitespaces),
					messages: messages,
					timeout: endpoint.timeout
				)
				let data = try await withDeadline(seconds: endpoint.timeout) { try await fetch(request) }
				return try AnthropicMessagesAPI.content(from: data)
			case .openAI:
				let effort = endpoint.reasoningEffort.trimmingCharacters(in: .whitespaces)
				do {
					return try await openAICompletion(endpoint, apiKey, messages, effort: effort.isEmpty ? nil : effort)
				} catch let ChatCompletionAPI.Failure.http(status, body) where status == 400 && !effort.isEmpty && body.localizedCaseInsensitiveContains("reasoning") {
					// Models differ in which efforts they take, and providers rename models; one that rejects the
					// setting still answers without it.
					HexLog.rewrite.notice("\(endpoint.model, privacy: .public) rejected reasoning effort \(effort, privacy: .public); retrying without it")
					return try await openAICompletion(endpoint, apiKey, messages, effort: nil)
				}
			}
		}

		return Self(
			complete: complete,
			listModels: { endpoint, apiKey in
				switch endpoint.provider.wire {
				case .onDevice:
					return LocalLLMModel.allCases.map(\.repository)
				case .anthropic:
					let data = try await fetch(try AnthropicMessagesAPI.modelsRequest(baseURL: endpoint.resolvedBaseURL, apiKey: apiKey))
					return try ChatCompletionAPI.modelIDs(from: data)
				case .openAI:
					let data = try await fetch(try ChatCompletionAPI.modelsRequest(baseURL: endpoint.resolvedBaseURL, apiKey: apiKey))
					return try ChatCompletionAPI.modelIDs(from: data)
						.map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
				}
			},
			stream: { endpoint, apiKey, messages in
				AsyncThrowingStream { continuation in
					let task = Task {
						do {
							// Only OpenAI-style servers stream here; the others answer in one piece.
							guard endpoint.provider.wire == .openAI else {
								continuation.yield(try await complete(endpoint, apiKey, messages))
								continuation.finish()
								return
							}
							let effort = endpoint.reasoningEffort.trimmingCharacters(in: .whitespaces)
							var body = ChatCompletionAPI.Request(
								model: endpoint.model.trimmingCharacters(in: .whitespaces),
								messages: messages,
								reasoningEffort: effort.isEmpty ? nil : effort
							)
							body.stream = true
							body.adapt(for: endpoint.provider)
							let request = try ChatCompletionAPI.chatRequest(
								baseURL: endpoint.resolvedBaseURL,
								apiKey: apiKey,
								body: body,
								timeout: endpoint.timeout
							)
							try await withDeadline(seconds: endpoint.timeout) {
								let (bytes, response) = try await session.bytes(for: request)
								let status = (response as? HTTPURLResponse)?.statusCode ?? 0
								guard (200 ..< 300).contains(status) else {
									var body = Data()
									for try await byte in bytes.prefix(2000) { body.append(byte) }
									try ChatCompletionAPI.checkStatus(status, data: body)
									return
								}
								var text = ""
								for try await line in bytes.lines {
									switch ChatCompletionAPI.streamEvent(fromLine: line) {
									case let .delta(piece):
										text += piece
										continuation.yield(text)
									case .done:
										return
									case .finished, nil:
										continue
									}
								}
							}
							continuation.finish()
						} catch {
							continuation.finish(throwing: error)
						}
					}
					continuation.onTermination = { _ in task.cancel() }
				}
			}
		)
	}
}

extension DependencyValues {
	var rewrite: RewriteClient {
		get { self[RewriteClient.self] }
		set { self[RewriteClient.self] = newValue }
	}
}

struct DeadlineExceeded: Error, LocalizedError {
	var seconds: Double
	var errorDescription: String? { "No answer within \(String(format: "%g", seconds)) s" }
}

/// Runs `operation`, cancelling it and throwing `DeadlineExceeded` if it outlasts `seconds`.
func withDeadline<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
	try await withThrowingTaskGroup(of: T.self) { group in
		group.addTask { try await operation() }
		group.addTask {
			try await Task.sleep(for: .seconds(seconds))
			throw DeadlineExceeded(seconds: seconds)
		}
		defer { group.cancelAll() }
		guard let result = try await group.next() else { throw CancellationError() }
		return result
	}
}
