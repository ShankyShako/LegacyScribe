import Darwin
import FluidAudio
import Foundation
import MLX

// lsbench --engine <id> --fixtures <dir> [--runs N] [--json out.json] [--cohere-chunk SECONDS] [--reload]
// lsbench rewrite --model <mlx-dir> --samples <file.jsonl> [--json out.json] [--no-think]   (see RewriteBench.swift)
//
// --reload: after the runs, unload the model and report the footprint right after and 5 s later
// (Metal returns memory lazily), then time a reload with warm-up.
//
// Engines:
//   cohere:<model-dir>            Cohere Transcribe via mlx-audio-swift, loaded from a local MLX checkpoint
//   parakeet:v2|v3|ultra|phonon2  Parakeet TDT via FluidAudio (downloads on first use)
//
// Fixtures: <name>.{wav,m4a,flac,caf} with an optional <name>.txt reference transcript.

struct FixtureResult: Codable {
    let fixture: String
    let audioSeconds: Double
    let latenciesMs: [Double]
    let medianMs: Double
    let realTimeFactor: Double
    let hypothesis: String
    let reference: String?
    let wer: WER.Result?
}

struct Report: Codable {
    let engine: String
    let machine: String
    let loadSeconds: Double
    let peakFootprintMB: Double
    let fixtures: [FixtureResult]
    let corpusWER: Double?
}

func peakFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.ledger_phys_footprint_peak) / 1_048_576 : -1
}

func currentFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func machineName() -> String {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
    let memGB = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
    return "\(String(cString: buffer)) \(memGB)GB macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
}

func makeEngine(_ spec: String, cohereChunkSeconds: Float?) throws -> BenchEngine {
    let modelsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LegacyScribe/Models/fluidaudio")
    let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
    switch (parts.first, parts.count > 1 ? parts[1] : nil) {
    case ("cohere", let dir?):
        let modelDir = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        if let cohereChunkSeconds { return CohereMLXEngine(modelDir: modelDir, chunkSeconds: cohereChunkSeconds) }
        return CohereMLXEngine(modelDir: modelDir)
    case ("apple", _): return AppleSpeechBenchEngine()
    case ("parakeet", "v2"): return ParakeetEngine(version: .v2, label: "v2", modelsRoot: modelsRoot)
    case ("parakeet", "v3"): return ParakeetEngine(version: .v3, label: "v3", modelsRoot: modelsRoot)
    case ("parakeet", "ultra"): return ParakeetEngine(version: .ultra, label: "ultra", modelsRoot: modelsRoot)
    case ("parakeet", "phonon2"): return ParakeetEngine(version: .phonon2, label: "phonon2", modelsRoot: modelsRoot)
    default: throw BenchError.usage("unknown engine '\(spec)'")
    }
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
}

func run() async throws {
    var args = Array(CommandLine.arguments.dropFirst())
    func option(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        defer { args.removeSubrange(i...(i + 1)) }
        return args[i + 1]
    }
    guard let engineSpec = option("--engine"), let fixturesPath = option("--fixtures") else {
        throw BenchError.usage("usage: lsbench --engine <cohere:DIR|parakeet:v2|v3|ultra|phonon2|apple> --fixtures DIR [--runs N] [--json FILE]")
    }
    let runs = option("--runs").flatMap(Int.init) ?? 3
    let jsonPath = option("--json")
    let cohereChunkSeconds = option("--cohere-chunk").flatMap(Float.init)
    let measureReload = args.contains("--reload")

    let fixturesDir = URL(fileURLWithPath: (fixturesPath as NSString).expandingTildeInPath)
    let audioFiles = try FileManager.default.contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil)
        .filter { ["wav", "m4a", "flac", "caf", "mp3"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !audioFiles.isEmpty else { throw BenchError.usage("no audio fixtures in \(fixturesDir.path)") }

    let converter = AudioConverter()
    let clips = try audioFiles.map { url -> (name: String, samples: [Float], reference: String?) in
        let reference = try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
        return (url.deletingPathExtension().lastPathComponent, try converter.resampleAudioFile(url), reference)
    }

    let engine = try makeEngine(engineSpec, cohereChunkSeconds: cohereChunkSeconds)
    FileHandle.standardError.write("loading \(engine.name)…\n".data(using: .utf8)!)
    let loadStart = ContinuousClock.now
    try await engine.load(warmup: Array(clips[0].samples.prefix(16_000 * 3)))
    let loadSeconds = (ContinuousClock.now - loadStart).seconds

    var results: [FixtureResult] = []
    var totalErrors = 0, totalWords = 0
    for clip in clips {
        var latencies: [Double] = []
        var hypothesis = ""
        for _ in 0..<runs {
            let start = ContinuousClock.now
            hypothesis = try await engine.transcribe(clip.samples)
            latencies.append((ContinuousClock.now - start).seconds * 1000)
        }
        let audioSeconds = Double(clip.samples.count) / 16_000
        let wer = clip.reference.map { WER.compute(reference: $0, hypothesis: hypothesis) }
        if let wer {
            totalErrors += wer.substitutions + wer.deletions + wer.insertions
            totalWords += wer.referenceWords
        }
        let med = median(latencies)
        results.append(FixtureResult(
            fixture: clip.name, audioSeconds: audioSeconds, latenciesMs: latencies, medianMs: med,
            realTimeFactor: audioSeconds / (med / 1000), hypothesis: hypothesis.trimmingCharacters(in: .whitespacesAndNewlines),
            reference: clip.reference?.trimmingCharacters(in: .whitespacesAndNewlines), wer: wer
        ))
        let werText = wer.map { String(format: "WER %5.1f%%", $0.rate * 100) } ?? "WER   n/a"
        print(clip.name.padding(toLength: 16, withPad: " ", startingAt: 0) + String(format: "%6.1fs audio  median %7.0f ms  RTFx %6.1f  ", audioSeconds, med, audioSeconds / (med / 1000)) + werText)
    }

    let report = Report(
        engine: engine.name, machine: machineName(), loadSeconds: loadSeconds, peakFootprintMB: peakFootprintMB(),
        fixtures: results, corpusWER: totalWords > 0 ? Double(totalErrors) / Double(totalWords) : nil
    )
    print(String(format: "\n%@  load %.1fs  peak footprint %.0f MB  corpus WER %@", engine.name, loadSeconds, report.peakFootprintMB,
                 report.corpusWER.map { String(format: "%.2f%%", $0 * 100) } ?? "n/a"))
    print(String(format: "footprint between clips %.0f MB; MLX active %d MB, cache %d MB", currentFootprintMB(), Memory.activeMemory >> 20, Memory.cacheMemory >> 20))
    if measureReload {
        engine.unload()
        print(String(format: "after unload %.0f MB; MLX active %d MB, cache %d MB", currentFootprintMB(), Memory.activeMemory >> 20, Memory.cacheMemory >> 20))
        try await Task.sleep(for: .seconds(5))
        print(String(format: "5 s later %.0f MB", currentFootprintMB()))
        let reloadStart = ContinuousClock.now
        try await engine.load(warmup: Array(clips[0].samples.prefix(16_000 * 3)))
        print(String(format: "reload + warm-up %.2f s, then %.0f MB", (ContinuousClock.now - reloadStart).seconds, currentFootprintMB()))
    }
    if let loops = option("--reload-loop").flatMap(Int.init) {
        // Leak check: load and unload repeatedly, then wait so `heap <pid>` can count what's left.
        for _ in 0..<loops {
            engine.unload()
            try await engine.load(warmup: Array(clips[0].samples.prefix(16_000 * 3)))
        }
        engine.unload()
        print("reload-loop done pid=\(ProcessInfo.processInfo.processIdentifier) footprint \(Int(currentFootprintMB())) MB")
        fflush(stdout)
        let end = Date().addingTimeInterval(600); while Date() < end { usleep(200_000) }
    }
    if let jsonPath {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: jsonPath))
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

do {
    if CommandLine.arguments.dropFirst().first == "rewrite" {
        try await runRewriteBench(Array(CommandLine.arguments.dropFirst(2)))
    } else if CommandLine.arguments.dropFirst().first == "vad" {
        try await runVadBench(Array(CommandLine.arguments.dropFirst(2)))
    } else if CommandLine.arguments.dropFirst().first == "align" {
        try await runAlignBench(Array(CommandLine.arguments.dropFirst(2)))
    } else {
        try await run()
    }
} catch {
    FileHandle.standardError.write("lsbench: \(error)\n".data(using: .utf8)!)
    exit(1)
}
