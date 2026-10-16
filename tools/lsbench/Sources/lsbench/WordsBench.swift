import FluidAudio
import Foundation
import HexCore

/// `lsbench words [--v2] <audio or folder>...`: one JSON line per clip with Parakeet TDT's words and their
/// timings (v3 by default), as the app groups them. For offline analysis of pauses and pace (speech coach).
func runWordsBench(_ arguments: [String]) async throws {
    var args = arguments
    var version: AsrModelVersion = .v3
    if let i = args.firstIndex(of: "--v2") {
        version = .v2
        args.remove(at: i)
    }
    let extensions: Set<String> = ["wav", "flac", "m4a", "caf", "mp3"]
    let files = args.flatMap { path -> [URL] in
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [url] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
            .map { url.appendingPathComponent($0) }
    }
    guard !files.isEmpty else {
        print("usage: lsbench words [--v2] <audio or folder>...")
        return
    }

    let modelsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LegacyScribe/Models/fluidaudio")
    let directory = modelsRoot.appendingPathComponent(AsrModels.defaultCacheDirectory(for: version).lastPathComponent)
    let tdt = AsrManager(config: .default, models: try await AsrModels.downloadAndLoad(to: directory, version: version))
    let converter = AudioConverter()
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys

    struct Line: Encodable {
        let file: String
        let seconds: Double
        let text: String
        let words: [SpokenWord]
    }
    for url in files {
        let samples = try converter.resampleAudioFile(url)
        var state = TdtDecoderState.make(decoderLayers: await tdt.decoderLayerCount)
        let result = try await tdt.transcribe(samples, decoderState: &state)
        let words = WordMatcher.words(fromPieces: (result.tokenTimings ?? []).map { ($0.token, $0.startTime, $0.endTime) })
        let line = Line(file: url.lastPathComponent, seconds: Double(samples.count) / 16_000, text: result.text, words: words)
        print(String(data: try encoder.encode(line), encoding: .utf8)!)
    }
}

/// `lsbench coach [--quiet] [--detail] <audio or folder>...`: the speech coach's analysis (`SpeechCoach`) of
/// each clip with Parakeet v3, then the summary and tips the Coach tab would show. `--quiet` prints only the
/// totals; `--detail` lists each pause with its level and any words Parakeet placed inside it.
func runCoachBench(_ arguments: [String]) async throws {
    var arguments = arguments
    let quiet = arguments.contains("--quiet")
    let detail = arguments.contains("--detail")
    arguments.removeAll { $0 == "--quiet" || $0 == "--detail" }
    let extensions: Set<String> = ["wav", "flac", "m4a", "caf", "mp3"]
    let files = arguments.flatMap { path -> [URL] in
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [url] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
            .map { url.appendingPathComponent($0) }
    }
    guard !files.isEmpty else {
        print("usage: lsbench coach <audio or folder>...")
        return
    }
    let modelsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LegacyScribe/Models/fluidaudio")
    let directory = modelsRoot.appendingPathComponent(AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent)
    let tdt = AsrManager(config: .default, models: try await AsrModels.downloadAndLoad(to: directory, version: .v3))
    let converter = AudioConverter()
    var clips: [CoachClip] = []
    // Pauses (silences ≥ 0.3 s inside the speech) and their seconds.
    var pauseCount = 0
    var pauseSeconds = 0.0
    var fluent = 0
    var analyseSeconds = 0.0
    var audioSeconds = 0.0
    for url in files {
        let samples = try converter.resampleAudioFile(url)
        let start = Date()
        var state = TdtDecoderState.make(decoderLayers: await tdt.decoderLayerCount)
        let result = try await tdt.transcribe(samples, decoderState: &state)
        let words = WordMatcher.words(fromPieces: (result.tokenTimings ?? []).map { ($0.token, $0.startTime, $0.endTime) })
        let transcript = Transcript(timestamp: Date(), text: result.text, audioPath: url, duration: Double(samples.count) / 16_000)
        let clip = SpeechCoach.clip(for: transcript, engine: "parakeet-v3", words: words, samples: samples, sampleRate: 16_000)
        analyseSeconds += Date().timeIntervalSince(start)
        audioSeconds += Double(samples.count) / 16_000
        clips.append(clip)
        fluent += clip.moments.filter { $0.kind == .fluent }.count
        let found = PauseFinder.pauses(in: samples, sampleRate: 16_000, words: words)
        pauseCount += found.count
        pauseSeconds += found.reduce(0) { $0 + $1.seconds }
        if detail {
            // Each pause with its level and any words Parakeet placed inside it.
            for pause in found {
                let from = Int(pause.start * 16_000), to = min(samples.count, Int((pause.start + pause.seconds) * 16_000))
                let rms = (samples[from ..< to].reduce(0) { $0 + $1 * $1 } / Float(max(1, to - from))).squareRoot()
                let inside = words.filter { $0.start > pause.start + 0.25 && $0.start < pause.start + pause.seconds - 0.5 }
                    .map { String(format: "%@@%.2f", $0.word, $0.start) }.joined(separator: " ")
                print(String(format: "    %6.2f +%.2f s  %5.1f dB  %@", pause.start, pause.seconds, 20 * log10(max(rms, 1e-6)), inside))
            }
            for moment in clip.moments where moment.kind == .fluent {
                let said = words.filter { $0.start >= moment.time - 0.01 && $0.start < moment.time + (moment.seconds ?? 0) }.map(\.word)
                print(String(format: "    clean %6.2f: %@", moment.time, said.joined(separator: " ")))
            }
        }
        if quiet { continue }
        let pauses = { (p: [Double]) in p.map { String(format: "%.1f", $0) }.joined(separator: " ") }
        print(String(
            format: "%@  %d words, %.0f wpm, fillers %@, corrections %@\n    crutches %@, hedges %@, sentences %@, run-ons %d, pitch range %@\n    sentence pauses [%@]  thought pauses [%@]",
            url.lastPathComponent, clip.words, Double(clip.words) / max(clip.speakingSeconds, 1) * 60,
            clip.fillers.description, clip.corrections.description, clip.crutches.description, clip.hedges.description,
            clip.sentenceLengths.description, clip.runOns,
            PitchTracker.semitoneRange(samples: samples, sampleRate: 16_000).map { String(format: "%.1f st", $0) } ?? "–",
            pauses(clip.sentencePauses), pauses(clip.thoughtPauses)
        ))
    }
    let summary = CoachSummary(clips)
    let o = summary.overall
    print(String(
        format: "\n%d clips, %.0f s audio analysed in %.1f s. Fillers %.1f/100 words, corrections %.1f/100, %.0f wpm overall, %.0f while speaking, pauses (median): sentence %.2f s, thought %.2f s, longest %.1f s, fillers in the first 2 s %.0f%%",
        o.dictations, audioSeconds, analyseSeconds, o.fillersPer100Words ?? 0, o.correctionsPer100Words ?? 0, o.wordsPerMinute ?? 0, o.speakingWordsPerMinute ?? 0,
        o.medianSentencePause ?? 0, o.medianThoughtPause ?? 0, o.longestPause ?? 0, (summary.openingFillerShare ?? 0) * 100
    ))
    for tip in summary.tips { print("tip: \(tip)") }
    print(String(
        format: "Pauses: %d (%.0f s). Clean sentences: %d in %d clips.",
        pauseCount, pauseSeconds, fluent, clips.filter { $0.moments.contains { $0.kind == .fluent } }.count
    ))
}
