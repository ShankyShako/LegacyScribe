import FluidAudio
import Foundation
import HexCore

/// `lsbench vad [--engine cohere:<dir>] <wav or folder>...`: what the notes speech gate (`NotesSpeech`,
/// Silero VAD with the app's settings) keeps of each clip. With `--engine`, each clip is also transcribed
/// whole and as the gate passes it, to see what silence or noise would have turned into.
func runVadBench(_ arguments: [String]) async throws {
    var args = arguments
    var engineSpec: String?
    if let i = args.firstIndex(of: "--engine"), i + 1 < args.count {
        engineSpec = args[i + 1]
        args.removeSubrange(i ... i + 1)
    }
    let files = args.flatMap { path -> [URL] in
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [url] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { $0.hasSuffix(".wav") }.sorted().map { url.appendingPathComponent($0) }
    }
    guard !files.isEmpty else {
        print("usage: lsbench vad [--engine cohere:<dir>] <wav or folder>...")
        return
    }

    let modelsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LegacyScribe/Models/fluidaudio")
    let loadStart = Date()
    let models = try await ModelHub.loadModels(.vad, modelNames: Array(ModelNames.VAD.requiredModels), directory: modelsRoot)
    guard let model = models[ModelNames.VAD.sileroVadFile] else { throw VadError.modelLoadingFailed }
    let vad = VadManager(vadModel: model)
    // The same as `NotesVoiceDetector`.
    let segmentation = VadSegmentationConfig(minSpeechDuration: 0.3, speechPadding: 0.3)
    print(String(format: "Silero VAD loaded in %.2f s", Date().timeIntervalSince(loadStart)))

    let engine = try engineSpec.map { try makeEngine($0, cohereChunkSeconds: nil) }
    let converter = AudioConverter()
    var loaded = false
    for url in files {
        let samples = try converter.resampleAudioFile(url)
        let start = Date()
        let segments = try await vad.segmentSpeech(samples, config: segmentation)
        let elapsed = Date().timeIntervalSince(start)
        let ranges = segments.map { $0.startSample(sampleRate: 16_000) ..< $0.endSample(sampleRate: 16_000) }
        let kept = NotesSpeech.joined(samples, ranges: ranges)
        let speech = segments.reduce(0) { $0 + $1.duration }
        print(String(
            format: "%@  %.1f s audio, %d stretches, %.1f s speech, %@ (%.0f ms)",
            url.lastPathComponent, Double(samples.count) / 16_000, segments.count, speech,
            kept == nil ? "skipped" : String(format: "keeps %.1f s", Double(kept!.count) / 16_000), elapsed * 1000
        ))
        guard let engine else { continue }
        if !loaded {
            try await engine.load(warmup: Array(samples.prefix(16_000 * 3)))
            loaded = true
        }
        let whole = try await engine.transcribe(samples)
        print("  whole: \(whole)\(NotesSpeech.looksLooped(whole) ? "  [looped]" : "")")
        if let kept {
            let gated = try await engine.transcribe(kept)
            print("  gated: \(gated)\(NotesSpeech.looksLooped(gated) ? "  [looped]" : "")")
        }
    }
}
