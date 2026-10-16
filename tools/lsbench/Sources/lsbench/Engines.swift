import FluidAudio
import Foundation
import HexCore
import MLX
import MLXAudioSTT

/// Minimal engine surface for benchmarking. The app's `SpeechEngine` protocol (P1) grows out of this.
protocol BenchEngine {
    var name: String { get }
    /// Load weights and run one throwaway inference so later timings are warm.
    func load(warmup: [Float]) async throws
    func transcribe(_ samples: [Float]) async throws -> String
    /// Drops the weights, so a reload can be timed.
    func unload()
}

extension BenchEngine {
    func unload() {}
}

final class CohereMLXEngine: BenchEngine {
    let name: String
    private let modelDir: URL
    private let chunkSeconds: Float?
    private var model: CohereTranscribeModel?

    /// Without `chunkSeconds`, audio is cut like the app's (`CohereChunks`); with it, mlx-audio's own splitter
    /// cuts every `chunkSeconds` (1200 = one pass). Cohere loses speech on clips over 35 s.
    init(modelDir: URL, chunkSeconds: Float? = nil) {
        self.modelDir = modelDir
        self.chunkSeconds = chunkSeconds
        self.name = "cohere-mlx:\(modelDir.lastPathComponent)"
    }

    func load(warmup: [Float]) async throws {
        model = try CohereTranscribeModel.fromDirectory(modelDir)
        _ = try await transcribe(warmup)
        // Building the model draws ~900 random keys lazily; unevaluated, the key chain is kept forever.
        eval(MLXRandom.globalState)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let model else { throw BenchError.notLoaded }
        if let chunkSeconds {
            let output = model.generate(
                audio: MLXArray(samples),
                generationParameters: STTGenerateParameters(language: "en", chunkDuration: chunkSeconds)
            )
            return output.text.replacingOccurrences(of: "\n", with: " ")
        }
        let parameters = STTGenerateParameters(language: "en", chunkDuration: Float(CohereChunks.singlePassSeconds) + 5)
        return CohereChunks.ranges(samples, sampleRate: 16_000).map { range in
            model.generate(audio: MLXArray(Array(samples[range])), generationParameters: parameters).text
                .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    func unload() {
        model = nil
        Memory.clearCache()
    }
}

final class ParakeetEngine: BenchEngine {
    let name: String
    private let version: AsrModelVersion
    private let modelsRoot: URL
    private var manager: AsrManager?

    init(version: AsrModelVersion, label: String, modelsRoot: URL) {
        self.version = version
        self.modelsRoot = modelsRoot
        self.name = "parakeet:\(label)"
    }

    func load(warmup: [Float]) async throws {
        // Same layout as the app's ParakeetClient, so downloads are shared.
        let directory = modelsRoot.appendingPathComponent(AsrModels.defaultCacheDirectory(for: version).lastPathComponent)
        let models = try await AsrModels.downloadAndLoad(to: directory, version: version)
        manager = AsrManager(config: .default, models: models)
        _ = try await transcribe(warmup)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw BenchError.notLoaded }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &state).text
    }
}

/// Apple's SpeechAnalyzer (macOS 26), through the same `AppleSpeech` code the app dictates with. It reads
/// files, so each clip goes through a temporary 16-bit WAV.
final class AppleSpeechBenchEngine: BenchEngine {
    let name = "apple:speech-analyzer"

    func load(warmup: [Float]) async throws {
        if !(await AppleSpeech.isInstalled()) {
            FileHandle.standardError.write("installing Apple's English speech model…\n".data(using: .utf8)!)
            try await AppleSpeech.install { _ in }
        }
        _ = try await transcribe(warmup)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lsbench-apple-\(UUID().uuidString).wav")
        try PCM16WAV.data(samples: samples).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await AppleSpeech.transcribe(url)
    }
}

enum BenchError: Error, CustomStringConvertible {
    case notLoaded
    case usage(String)

    var description: String {
        switch self {
        case .notLoaded: "engine used before load()"
        case .usage(let message): message
        }
    }
}
