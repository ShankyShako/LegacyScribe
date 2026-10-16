import Foundation
import HexCore
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

// lsbench rewrite --model <mlx-dir> --samples <file.jsonl> [--json out.json] [--no-think] [--messages out.jsonl]
//
// Runs the app's rewrite prompts (RewritePromptBuilder, RewriteOutputSanitizer, RewriteChain's length check)
// through an on-device MLX model. Each sample line: {"mode": "clean"|"prompt", "transcript": "...",
// "reference": "..."} where reference is another model's rewrite to compare by eye. A "super" sample's
// transcript is the instruction (SuperPrompt): with "selection" it edits that text, otherwise it writes at
// the end of "field" (optional). An "s1" sample runs S1-mini's fixed normalizer prompt (Superwhisper's
// Qwen3-0.6B fine-tune) with `[Styling: semi-formal] [Structure: prose] [Context: general]` unless "control"
// gives another line; it is decoded greedily, as its model card asks. A "chat" sample sends its "system" text and
// the transcript as the user message, greedy too (for fine-tuned models trained on that shape). "append" adds
// text to the end of a clean/prompt sample's system message.

struct RewriteSample: Codable {
    let mode: String
    let transcript: String
    let reference: String?
    let selection: String?
    let field: String?
    let control: String?
    let system: String?
    /// Text added to the end of the system message, to try an instruction without changing the app's prompts.
    let append: String?

    static let s1System = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."

    /// The chat messages and the length check the app would use.
    func request() -> (messages: [ChatMessage], rejection: (String) -> String?)? {
        if mode == "s1" {
            let line = control ?? "[Styling: semi-formal] [Structure: prose] [Context: general]"
            return ([ChatMessage(role: "system", content: Self.s1System), ChatMessage(role: "user", content: "\(line)\n\(transcript)")], {
                RewriteChain.rejection(of: $0, transcript: transcript)
            })
        }
        if mode == "chat" {
            return ([ChatMessage(role: "system", content: system ?? ""), ChatMessage(role: "user", content: transcript)], {
                RewriteChain.rejection(of: $0, transcript: transcript)
            })
        }
        if mode == "super" {
            let request: SuperRequest = selection.map { .edit(selection: $0) } ?? .write(before: field ?? "", after: "")
            return (SuperPrompt.messages(instruction: transcript, request: request), {
                SuperPrompt.rejection(of: $0, instruction: transcript, request: request)
            })
        }
        guard let mode = RewriteMode(rawValue: mode),
              var messages = RewritePromptBuilder.messages(mode: mode, transcript: transcript, vocabulary: [])
        else { return nil }
        if let append, let i = messages.firstIndex(where: { $0.role == "system" }) {
            messages[i].content += "\n\n" + append
        }
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
    /// A greedy run hit its cap and was run again with a repetition penalty.
    let retried: Bool
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
    // --messages FILE: write each sample's chat messages as JSON lines and stop (to send them to another endpoint).
    if let messagesPath = option("--messages") {
        let samples = try String(contentsOfFile: (samplesPath as NSString).expandingTildeInPath, encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(RewriteSample.self, from: Data($0.utf8)) }
        let lines = try samples.compactMap { $0.request()?.messages }.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(toFile: messagesPath, atomically: true, encoding: .utf8)
        return
    }
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
        // Small greedy models ("s1", "chat") get a cap near the dictation's length and, if they hit it (a loop),
        // one retry with repetition penalty 1.1, as on-device notes do.
        let greedy = ["s1", "chat"].contains(sample.mode)
        let words = sample.transcript.split(separator: " ").count
        var parameters = GenerateParameters(maxTokens: greedy ? words * 5 / 2 + 64 : 4096, temperature: greedy ? 0 : 0.2)
        var (text, info) = try await generate(messages, templateValues, parameters, container)
        var retried = false
        if greedy, info?.stopReason == .length {
            retried = true
            parameters.repetitionPenalty = 1.1
            (text, info) = try await generate(messages, templateValues, parameters, container)
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
            retried: retried,
            rejected: rejection(output),
            output: output,
            reference: sample.reference
        )
        results.append(result)
        print(String(format: "%-6@ %4d words  %5.2f s  prompt %4d tok  out %4d tok @ %.0f tok/s%@%@",
                     sample.mode, result.words, seconds, result.promptTokens, result.outputTokens, result.tokensPerSecond,
                     result.truncated ? "  TRUNCATED" : (retried ? "  RETRIED" : ""), result.rejected.map { "  REJECTED: \($0)" } ?? ""))
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

private func generate(
    _ messages: [ChatMessage], _ templateValues: [String: any Sendable]?, _ parameters: GenerateParameters, _ container: ModelContainer
) async throws -> (String, GenerateCompletionInfo?) {
    try await container.perform { context in
        let chat: [Chat.Message] = messages.map {
            $0.role == "system" ? .system($0.content) : .user($0.content)
        }
        let input = try await context.processor.prepare(input: UserInput(chat: chat, additionalContext: templateValues))
        var text = ""
        var info: GenerateCompletionInfo?
        for await item in try MLXLMCommon.generate(input: input, parameters: parameters, context: context) {
            switch item {
            case let .chunk(piece): text += piece
            case let .info(completion): info = completion
            default: break
            }
        }
        return (text, info)
    }
}
