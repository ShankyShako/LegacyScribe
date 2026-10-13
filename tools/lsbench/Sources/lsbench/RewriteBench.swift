import Foundation
import HexCore
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

// lsbench rewrite --model <mlx-dir> --samples <file.jsonl> [--json out.json] [--no-think]
//
// Runs the app's rewrite prompts (RewritePromptBuilder, RewriteOutputSanitizer, RewriteChain's length check)
// through an on-device MLX model. Each sample line: {"mode": "clean"|"prompt", "transcript": "...",
// "reference": "..."} where reference is another model's rewrite to compare by eye. A "super" sample's
// transcript is the instruction (SuperPrompt): with "selection" it edits that text, otherwise it writes at
// the end of "field" (optional).

struct RewriteSample: Codable {
    let mode: String
    let transcript: String
    let reference: String?
    let selection: String?
    let field: String?

    /// The chat messages and the length check the app would use.
    func request() -> (messages: [ChatMessage], rejection: (String) -> String?)? {
        if mode == "super" {
            let request: SuperRequest = selection.map { .edit(selection: $0) } ?? .write(before: field ?? "", after: "")
            return (SuperPrompt.messages(instruction: transcript, request: request), {
                SuperPrompt.rejection(of: $0, instruction: transcript, request: request)
            })
        }
        guard let mode = RewriteMode(rawValue: mode),
              let messages = RewritePromptBuilder.messages(mode: mode, transcript: transcript, vocabulary: [])
        else { return nil }
        return (messages, { RewriteChain.rejection(of: $0, transcript: transcript) })
    }
}

struct RewriteResult: Codable {
    let mode: String
    let words: Int
    let promptTokens: Int
    let outputTokens: Int
    let seconds: Double
    let tokensPerSecond: Double
    let truncated: Bool
    /// Why the app would refuse to paste `output`; nil when it would paste it.
    let rejected: String?
    let output: String
    let reference: String?
}

struct RewriteReport: Codable {
    let model: String
    let machine: String
    let loadSeconds: Double
    let peakFootprintMB: Double
    let results: [RewriteResult]
}

private struct TokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        Bridge(try await AutoTokenizer.from(modelFolder: directory))
    }

    struct Bridge: MLXLMCommon.Tokenizer {
        let upstream: any Tokenizers.Tokenizer
        init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }
        func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
        func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
        func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
        var bosToken: String? { upstream.bosToken }
        var eosToken: String? { upstream.eosToken }
        var unknownToken: String? { upstream.unknownToken }
        func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
            try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        }
    }
}

func runRewriteBench(_ args: [String]) async throws {
    func option(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    guard let modelPath = option("--model"), let samplesPath = option("--samples") else {
        throw BenchError.usage("usage: lsbench rewrite --model DIR --samples FILE.jsonl [--json FILE] [--no-think]")
    }
    let noThink = args.contains("--no-think")
    let modelDir = URL(fileURLWithPath: (modelPath as NSString).expandingTildeInPath)
    let samples = try String(contentsOfFile: (samplesPath as NSString).expandingTildeInPath, encoding: .utf8)
        .split(separator: "\n")
        .map { try JSONDecoder().decode(RewriteSample.self, from: Data($0.utf8)) }

    let loadStart = ContinuousClock.now
    let container = try await LLMModelFactory.shared.loadContainer(from: modelDir, using: TokenizerLoader())
    let loadSeconds = (ContinuousClock.now - loadStart).seconds
    print(String(format: "%@  load %.2f s", modelDir.lastPathComponent, loadSeconds))

    var results: [RewriteResult] = []
    for sample in samples {
        guard let (messages, rejection) = sample.request() else { continue }
        let templateValues: [String: any Sendable]? = noThink ? ["enable_thinking": false] : nil
        let start = ContinuousClock.now
        let (text, info) = try await container.perform { context in
            let chat: [Chat.Message] = messages.map {
                $0.role == "system" ? .system($0.content) : .user($0.content)
            }
            let input = try await context.processor.prepare(input: UserInput(chat: chat, additionalContext: templateValues))
            var text = ""
            var info: GenerateCompletionInfo?
            for await item in try MLXLMCommon.generate(
                input: input, parameters: GenerateParameters(maxTokens: 4096, temperature: 0.2), context: context
            ) {
                switch item {
                case let .chunk(piece): text += piece
                case let .info(completion): info = completion
                default: break
                }
            }
            return (text, info)
        }
        let seconds = (ContinuousClock.now - start).seconds
        let output = RewriteOutputSanitizer.sanitize(text)
        let result = RewriteResult(
            mode: sample.mode,
            words: sample.transcript.split(separator: " ").count,
            promptTokens: info?.promptTokenCount ?? 0,
            outputTokens: info?.generationTokenCount ?? 0,
            seconds: seconds,
            tokensPerSecond: info.map { Double($0.generationTokenCount) / max($0.generateTime, 0.001) } ?? 0,
            truncated: info?.stopReason == .length,
            rejected: rejection(output),
            output: output,
            reference: sample.reference
        )
        results.append(result)
        print(String(format: "%-6@ %4d words  %5.2f s  prompt %4d tok  out %4d tok @ %.0f tok/s%@%@",
                     sample.mode, result.words, seconds, result.promptTokens, result.outputTokens, result.tokensPerSecond,
                     result.truncated ? "  TRUNCATED" : "", result.rejected.map { "  REJECTED: \($0)" } ?? ""))
    }
    let report = RewriteReport(
        model: modelDir.lastPathComponent, machine: machineName(), loadSeconds: loadSeconds,
        peakFootprintMB: peakFootprintMB(), results: results
    )
    print(String(format: "peak footprint %.0f MB", report.peakFootprintMB))
    if let jsonPath = option("--json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: jsonPath))
    }
}
