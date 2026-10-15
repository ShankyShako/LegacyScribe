import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Runs a downloaded `LocalLLMModel` in-process with MLX: no server, no key, nothing leaves the Mac.
/// Like Cohere it's loaded when needed (the talk key going down warms it) and unloaded after the rewrite,
/// so the app doesn't hold gigabytes while idle.
actor LocalLLM {
  static let shared = LocalLLM()

  private var container: ModelContainer?
  private var loadedRepository: String?
  private let logger = HexLog.rewrite

  enum Failure: Error, LocalizedError {
    case unknownModel(String)
    case notDownloaded(String)

    var errorDescription: String? {
      switch self {
      case let .unknownModel(repository): "Unknown on-device model: \(repository)"
      case let .notDownloaded(repository):
        "\(LocalLLMModel(rawValue: repository)?.displayName ?? repository) isn't downloaded yet (Settings > AI Rewrite)"
      }
    }
  }

  nonisolated static func directory(for model: LocalLLMModel) throws -> URL {
    try URL.hexMLXModelsDirectory.appendingPathComponent(model.repository, isDirectory: true)
  }

  /// Weights, config and tokenizer are all present (a download leaves only `.partial` files until a file is whole).
  nonisolated static func isDownloaded(_ model: LocalLLMModel) -> Bool {
    guard let directory = try? directory(for: model) else { return false }
    let fm = FileManager.default
    let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
    guard names.contains("config.json"), names.contains("tokenizer.json"),
          !names.contains(where: { $0.hasSuffix(".partial") }) else { return false }
    // Sharded checkpoints list every weight file in the index.
    if let index = try? Data(contentsOf: directory.appendingPathComponent("model.safetensors.index.json")),
       let json = try? JSONSerialization.jsonObject(with: index) as? [String: Any],
       let map = json["weight_map"] as? [String: String] {
      return Set(map.values).allSatisfy(names.contains)
    }
    return names.contains { $0.hasSuffix(".safetensors") }
  }

  func download(_ model: LocalLLMModel, progress: @escaping @Sendable (Double) -> Void) async throws {
    try await HuggingFaceDownloader.download(
      model.repository,
      to: try Self.directory(for: model),
      wanted: LocalLLMModel.isNeeded,
      progress: progress
    )
  }

  func delete(_ model: LocalLLMModel) throws {
    if loadedRepository == model.repository { unload() }
    let directory = try Self.directory(for: model)
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
  }

  func unload() {
    guard container != nil else { return }
    container = nil
    loadedRepository = nil
    Memory.clearCache()
    logger.notice("On-device model unloaded")
  }

  /// Loads the model if it's downloaded and not loaded yet; quiet otherwise. Called when the talk key goes down.
  func prewarm(_ repository: String) async {
    guard let model = LocalLLMModel(rawValue: repository), Self.isDownloaded(model) else { return }
    do {
      _ = try await load(model)
    } catch {
      logger.error("Warming \(repository, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func load(_ model: LocalLLMModel) async throws -> ModelContainer {
    if let container, loadedRepository == model.repository { return container }
    unload()
    guard Self.isDownloaded(model) else { throw Failure.notDownloaded(model.repository) }
    let start = ContinuousClock.now
    let loaded = try await LLMModelFactory.shared.loadContainer(
      from: try Self.directory(for: model),
      using: TransformersTokenizerLoader()
    )
    // Building the model draws random keys lazily; unevaluated, the key chain is kept forever.
    eval(MLXRandom.globalState)
    container = loaded
    loadedRepository = model.repository
    logger.notice("Loaded \(model.repository, privacy: .public) in \(String(describing: ContinuousClock.now - start), privacy: .public)")
    return loaded
  }

  /// One chat completion. Throws `ChatCompletionAPI.Failure.truncated` when `maxTokens` cuts the answer off.
  func complete(
    repository: String,
    messages: [ChatMessage],
    maxTokens: Int = ChatCompletionAPI.defaultMaxTokens,
    temperature: Float = 0.2,
    repetitionPenalty: Float? = nil
  ) async throws -> String {
    guard let model = LocalLLMModel(rawValue: repository) else { throw Failure.unknownModel(repository) }
    let container = try await load(model)
    let templateValues: [String: any Sendable]? = model.hasThinkingSwitch ? ["enable_thinking": false] : nil
    let parameters = GenerateParameters(maxTokens: maxTokens, temperature: temperature, repetitionPenalty: repetitionPenalty)
    let start = ContinuousClock.now
    let (text, info) = try await container.perform { context in
      // Built in here: Chat.Message isn't Sendable.
      let chat: [Chat.Message] = messages.map { message in
        switch message.role {
        case "system": .system(message.content)
        case "assistant": .assistant(message.content)
        default: .user(message.content)
        }
      }
      let input = try await context.processor.prepare(input: UserInput(chat: chat, additionalContext: templateValues))
      var text = ""
      var info: GenerateCompletionInfo?
      for await item in try MLXLMCommon.generate(input: input, parameters: parameters, context: context) {
        try Task.checkCancellation()
        switch item {
        case let .chunk(piece): text += piece
        case let .info(completion): info = completion
        default: break
        }
      }
      return (text, info)
    }
    if info?.stopReason == .length { throw ChatCompletionAPI.Failure.truncated }
    if let info {
      logger.info("\(repository, privacy: .public): \(info.promptTokenCount) prompt + \(info.generationTokenCount) tokens in \(String(describing: ContinuousClock.now - start), privacy: .public)")
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatCompletionAPI.Failure.emptyResponse }
    return text
  }
}

/// Bridges swift-transformers' tokenizer to MLXLMCommon's (what `#huggingFaceTokenizerLoader()` expands to,
/// without pulling in the macro target).
private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
  func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
    Bridge(try await AutoTokenizer.from(modelFolder: directory))
  }

  struct Bridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
      upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
      upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
      messages: [[String: any Sendable]],
      tools: [[String: any Sendable]]?,
      additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
      do {
        return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
      } catch Tokenizers.TokenizerError.missingChatTemplate {
        throw MLXLMCommon.TokenizerError.missingChatTemplate
      }
    }
  }
}

/// On-device model downloads and status for Settings, and warming for dictation.
@DependencyClient
struct LocalLLMClient {
  var isDownloaded: @Sendable (LocalLLMModel) -> Bool = { _ in false }
  var download: @Sendable (LocalLLMModel, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void
  var delete: @Sendable (LocalLLMModel) async throws -> Void
  var prewarm: @Sendable (_ repository: String) async -> Void = { _ in }
  var unload: @Sendable () async -> Void = {}
}

extension LocalLLMClient: DependencyKey {
  static var liveValue: Self {
    Self(
      isDownloaded: { LocalLLM.isDownloaded($0) },
      download: { try await LocalLLM.shared.download($0, progress: $1) },
      delete: { try await LocalLLM.shared.delete($0) },
      prewarm: { await LocalLLM.shared.prewarm($0) },
      unload: { await LocalLLM.shared.unload() }
    )
  }
  /// Warming and unloading are fire-and-forget, so tests don't have to stub them; nothing is downloaded.
  static var testValue: Self {
    var client = Self()
    client.isDownloaded = { _ in false }
    client.prewarm = { _ in }
    client.unload = {}
    return client
  }
}

extension DependencyValues {
  var localLLM: LocalLLMClient {
    get { self[LocalLLMClient.self] }
    set { self[LocalLLMClient.self] = newValue }
  }
}
