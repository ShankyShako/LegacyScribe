import FluidAudio
import Foundation
import MLX
import MLXAudioSTT

/// Minimal engine surface for benchmarking. The app's `SpeechEngine` protocol (P1) grows out of this.
protocol BenchEngine {
    var name: String { get }
    /// Load weights and run one throwaway inference so later timings are warm.
    func load(warmup: [Float]) async throws
    func transcribe(_ samples: [Float]) async throws -> String
}

final class CohereMLXEngine: BenchEngine {
    let name: String
    private let modelDir: URL
    private var model: CohereTranscribeModel?

    init(modelDir: URL) {
        self.modelDir = modelDir
        self.name = "cohere-mlx:\(modelDir.lastPathComponent)"
    }

    func load(warmup: [Float]) async throws {
        model = try CohereTranscribeModel.fromDirectory(modelDir)
        _ = try await transcribe(warmup)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let model else { throw BenchError.notLoaded }
        let output = model.generate(
            audio: MLXArray(samples),
            generationParameters: STTGenerateParameters(language: "en")
        )
        return output.text
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
