import Foundation
import HexCore
import PhononCoreML

/// Fermion Research's own Core ML runtime for Phonon-2 (`phonon-coreml` 1.1.2, `Transcriber`). The first load
/// compiles the encoder for the Neural Engine (1-2 min); `compileSeconds` reports it and later loads reuse the copy.
final class FermionEngine: BenchEngine, TimedBenchEngine {
    let name = "fermion:phonon2"
    private let bundle: URL
    private var transcriber: Transcriber?
    private(set) var firstLoadSeconds = 0.0
    private(set) var compileSeconds = 0.0

    init(bundle: URL) { self.bundle = bundle }

    func load(warmup: [Float]) async throws {
        let start = ContinuousClock.now
        let t = try Transcriber(bundle: bundle)
        transcriber = t
        compileSeconds = t.compileSeconds
        firstLoadSeconds = (ContinuousClock.now - start).seconds
        // The 5, 10 and 35 s encoder functions load lazily; load them now so no timed clip pays for it.
        let preload = ContinuousClock.now
        try t.preloadAllFunctions()
        let preloadSeconds = (ContinuousClock.now - preload).seconds
        FileHandle.standardError.write(String(format: "fermion load: init %.2f s (compile step %.2f s, Transcriber.loadSeconds %.2f s), other functions %.2f s\n",
                                              firstLoadSeconds, compileSeconds, t.loadSeconds, preloadSeconds).data(using: .utf8)!)
        _ = try t.transcribe(warmup)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let transcriber else { throw BenchError.notLoaded }
        return try transcriber.transcribe(samples).text
    }

    func transcribeTimed(_ samples: [Float]) async throws -> (text: String, words: [SpokenWord]) {
        guard let transcriber else { throw BenchError.notLoaded }
        let result = try transcriber.transcribe(samples)
        return (result.text, result.words.map { SpokenWord(word: $0.text, start: $0.start, end: $0.end) })
    }

    func unload() { transcriber = nil }
}

/// Engines that also return per-word timings, for `lsbench align`.
protocol TimedBenchEngine {
    func transcribeTimed(_ samples: [Float]) async throws -> (text: String, words: [SpokenWord])
}
