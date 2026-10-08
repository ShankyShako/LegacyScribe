import Dependencies
import DependenciesMacros
import Foundation
import HexCore

/// Talks to OpenAI-compatible chat endpoints (OmniRoute, Ollama, …) for the LLM rewrite step.
@DependencyClient
struct RewriteClient {
	/// One chat completion. Throws on HTTP errors, a cut-off answer, or when `endpoint.timeout` passes.
	var complete: @Sendable (_ endpoint: RewriteEndpoint, _ apiKey: String?, _ messages: [ChatMessage]) async throws -> String
	var listModels: @Sendable (_ baseURL: String, _ apiKey: String?) async throws -> [String]
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

		return Self(
			complete: { endpoint, apiKey, messages in
				let effort = endpoint.reasoningEffort.trimmingCharacters(in: .whitespaces)
				let body = ChatCompletionAPI.Request(
					model: endpoint.model.trimmingCharacters(in: .whitespaces),
					messages: messages,
					reasoningEffort: effort.isEmpty ? nil : effort
				)
				let request = try ChatCompletionAPI.chatRequest(
					baseURL: endpoint.baseURL,
					apiKey: apiKey,
					body: body,
					timeout: endpoint.timeout
				)
				// URLRequest's timeout resets on every received packet; this caps the whole call.
				let data = try await withDeadline(seconds: endpoint.timeout) { try await fetch(request) }
				return try ChatCompletionAPI.content(from: data)
			},
			listModels: { baseURL, apiKey in
				let data = try await fetch(try ChatCompletionAPI.modelsRequest(baseURL: baseURL, apiKey: apiKey))
				return try ChatCompletionAPI.modelIDs(from: data)
			},
			stream: { endpoint, apiKey, messages in
				AsyncThrowingStream { continuation in
					let task = Task {
						do {
							let effort = endpoint.reasoningEffort.trimmingCharacters(in: .whitespaces)
							var body = ChatCompletionAPI.Request(
								model: endpoint.model.trimmingCharacters(in: .whitespaces),
								messages: messages,
								reasoningEffort: effort.isEmpty ? nil : effort
							)
							body.stream = true
							let request = try ChatCompletionAPI.chatRequest(
								baseURL: endpoint.baseURL,
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
