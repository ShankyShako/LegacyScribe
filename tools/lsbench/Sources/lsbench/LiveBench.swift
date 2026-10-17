import FluidAudio
import Foundation
import HexCore

private let audioExtensions: Set<String> = ["wav", "m4a", "flac", "caf", "mp3"]

func audioFiles(in paths: [String]) -> [URL] {
    paths.flatMap { path -> [URL] in
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [url] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
            .map { url.appendingPathComponent($0) }
    }
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

/// Seconds into the clip where the signal first rises above -40 dBFS in a 20 ms block.
func speechOnset(_ samples: [Float]) -> Double {
    let block = 320
    var start = 0
    while start + block <= samples.count {
        var sum: Float = 0
        for i in start ..< start + block { sum += samples[i] * samples[i] }
        if (sum / Float(block)).squareRoot() > 0.01 { return Double(start) / 16_000 }
        start += block
    }
    return 0
}

/// Word-level edit alignment between two consecutive live texts. Returns how many words of `old` are not
/// kept as the same word in `new`, and how many of those sit before the last `tail` words of `old`.
func changedWords(old: [String], new: [String], tail: Int = 2) -> (changed: Int, settled: Int) {
    let n = old.count, m = new.count
    guard n > 0 else { return (0, 0) }
    var cost = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    for i in 0 ... n { cost[i][0] = i }
    for j in 0 ... m { cost[0][j] = j }
    if m > 0 {
        for i in 1 ... n {
            for j in 1 ... m {
                cost[i][j] = min(cost[i - 1][j - 1] + (old[i - 1] == new[j - 1] ? 0 : 1), cost[i - 1][j] + 1, cost[i][j - 1] + 1)
            }
        }
    }
    var kept = [Bool](repeating: false, count: n)
    var i = n, j = m
    while i > 0 && j > 0 {
        if old[i - 1] == new[j - 1], cost[i][j] == cost[i - 1][j - 1] {
            kept[i - 1] = true; i -= 1; j -= 1
        } else if cost[i][j] == cost[i - 1][j - 1] + 1 {
            i -= 1; j -= 1
        } else if cost[i][j] == cost[i - 1][j] + 1 {
            i -= 1
        } else {
            j -= 1
        }
    }
    var changed = 0, settled = 0
    for k in 0 ..< n where !kept[k] {
        changed += 1
        if k < n - tail { settled += 1 }
    }
    return (changed, settled)
}

/// `lsbench live --engine <spec> [--step 0.4] [--json out.json] <audio or folder>...`
///
/// Live text as a caption would show it: every `step` seconds the prefix [0, t] of the clip is transcribed
/// again (the app's `SpeechPeekClient` does this with Apple Speech). Per engine it reports each pass's
/// latency (overall and by prefix length), the time from the first speech to the first word and to the first
/// correct word, and stability: how many already shown words a later pass changed. A `.txt` next to a clip is
/// its reference (final-pass WER, first-word check).
///
/// `lsbench live --engine <spec> --heads 1.0,1.7,2.5,3.3 <audio or folder>...` instead prints what the engine
/// writes for the first N seconds of each clip, the early check for the spoken "Legacy"/"Lucy" trigger.
func runLiveBench(_ arguments: [String]) async throws {
    var args = arguments
    func option(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        defer { args.removeSubrange(i...(i + 1)) }
        return args[i + 1]
    }
    guard let spec = option("--engine") else {
        throw BenchError.usage("usage: lsbench live --engine <spec> [--step 0.4] [--heads 1.0,1.7,2.5,3.3] [--json out.json] <audio or folder>...")
    }
    if args.contains("--stream") { try await runLiveStreamBench(arguments); return }
    let step = option("--step").flatMap(Double.init) ?? 0.4
    let heads = option("--heads")?.split(separator: ",").compactMap { Double($0) }
    let jsonPath = option("--json")
    let files = audioFiles(in: args)
    guard !files.isEmpty else { throw BenchError.usage("no audio files") }

    let converter = AudioConverter()
    let clips = try files.map { url -> (name: String, samples: [Float], reference: String?) in
        let reference = try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
        return (url.deletingPathExtension().lastPathComponent, try converter.resampleAudioFile(url), reference)
    }
    let engine = try makeEngine(spec, cohereChunkSeconds: nil)
    FileHandle.standardError.write("loading \(engine.name)…\n".data(using: .utf8)!)
    try await engine.load(warmup: Array(clips[0].samples.prefix(16_000 * 3)))

    if let heads {
        struct Head: Codable { let clip: String; let seconds: Double; let text: String; let latencyMs: Double; let verdict: String }
        var out: [Head] = []
        for clip in clips {
            for seconds in heads {
                let prefix = Array(clip.samples.prefix(Int(seconds * 16_000)))
                let start = ContinuousClock.now
                let text = try await engine.transcribe(prefix).trimmingCharacters(in: .whitespacesAndNewlines)
                let ms = (ContinuousClock.now - start).seconds * 1000
                let first = WER.normalize(text).first ?? ""
                let early = SuperTrigger.earlyVerdict(text)
                let verdict = early.isSuper == true ? "SUPER" : (early.isSuper == nil ? (text.isEmpty ? "empty" : "undecided") : "not-super")
                out.append(Head(clip: clip.name, seconds: seconds, text: text, latencyMs: ms, verdict: verdict))
                print(String(format: "%@  %.1fs  %5.0f ms  %@  \"%@\"", clip.name.padding(toLength: 24, withPad: " ", startingAt: 0), seconds, ms, verdict.padding(toLength: 12, withPad: " ", startingAt: 0), text))
            }
        }
        if let jsonPath {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(out).write(to: URL(fileURLWithPath: jsonPath))
        }
        return
    }

    struct Pass: Codable { let t: Double; let latencyMs: Double; let text: String }
    struct ClipResult: Codable {
        let clip: String; let seconds: Double; let onset: Double
        let passes: [Pass]
        let finalWER: Double?
        let firstWordMs: Double?        // from speech onset to the first pass that shows any word, pass latency included
        let firstCorrectMs: Double?     // ... to the first pass whose first word is the reference's first word
        let changedWords: Int           // already shown words that a later pass changed or dropped
        let settledChanges: Int         // ... not counting the last two words of the older pass
        let finalWords: Int
    }
    var results: [ClipResult] = []
    var totalErrors = 0, totalWords = 0
    for clip in clips {
        let duration = Double(clip.samples.count) / 16_000
        var times: [Double] = []
        var t = step
        while t < duration - 0.05 { times.append(t); t += step }
        times.append(duration)
        let onset = speechOnset(clip.samples)
        var passes: [Pass] = []
        for t in times {
            let prefix = Array(clip.samples.prefix(Int(t * 16_000)))
            let start = ContinuousClock.now
            let text = try await engine.transcribe(prefix).trimmingCharacters(in: .whitespacesAndNewlines)
            passes.append(Pass(t: t, latencyMs: (ContinuousClock.now - start).seconds * 1000, text: text))
        }
        let refWords = clip.reference.map { WER.normalize($0) } ?? []
        var firstWord: Double?, firstCorrect: Double?
        for pass in passes {
            let words = WER.normalize(pass.text)
            let shown = (pass.t + pass.latencyMs / 1000 - onset) * 1000
            if firstWord == nil, !words.isEmpty { firstWord = shown }
            if firstCorrect == nil, let r = refWords.first, words.first == r { firstCorrect = shown }
        }
        var changed = 0, settled = 0
        for (a, b) in zip(passes, passes.dropFirst()) {
            let c = changedWords(old: WER.normalize(a.text), new: WER.normalize(b.text))
            changed += c.changed; settled += c.settled
        }
        let finalText = passes.last?.text ?? ""
        let wer = clip.reference.map { WER.compute(reference: $0, hypothesis: finalText) }
        if let wer { totalErrors += wer.substitutions + wer.deletions + wer.insertions; totalWords += wer.referenceWords }
        let result = ClipResult(clip: clip.name, seconds: duration, onset: onset, passes: passes, finalWER: wer?.rate,
                                firstWordMs: firstWord, firstCorrectMs: firstCorrect, changedWords: changed, settledChanges: settled,
                                finalWords: WER.normalize(finalText).count)
        results.append(result)
        print(String(format: "%@ %5.1fs  %3d passes  first word %@  first correct %@  changed %3d (settled %3d) of %3d words  final WER %@",
                     clip.name.padding(toLength: 22, withPad: " ", startingAt: 0), duration, passes.count,
                     firstWord.map { String(format: "%5.0f ms", $0) } ?? "    n/a", firstCorrect.map { String(format: "%5.0f ms", $0) } ?? "    n/a",
                     changed, settled, result.finalWords, wer.map { String(format: "%.1f%%", $0.rate * 100) } ?? "n/a"))
    }

    let all = results.flatMap(\.passes)
    let latencies = all.map(\.latencyMs)
    print("\n\(engine.name): \(results.count) clips, \(all.count) passes, step \(step) s")
    print(String(format: "pass latency: median %.0f ms, p95 %.0f ms, max %.0f ms", percentile(latencies, 0.5), percentile(latencies, 0.95), latencies.max() ?? 0))
    for (low, high) in [(0.0, 5.0), (5, 10), (10, 20), (20, 40), (40, 1000)] {
        let bucket = all.filter { $0.t > low && $0.t <= high }.map(\.latencyMs)
        guard !bucket.isEmpty else { continue }
        print(String(format: "  prefix %3.0f-%-4.0f s: %4d passes, median %5.0f ms, p95 %5.0f ms", low, min(high, 999), bucket.count, percentile(bucket, 0.5), percentile(bucket, 0.95)))
    }
    let fw = results.compactMap(\.firstWordMs), fc = results.compactMap(\.firstCorrectMs)
    print(String(format: "first word after speech onset: median %.0f ms, p95 %.0f ms (%d of %d clips)", percentile(fw, 0.5), percentile(fw, 0.95), fw.count, results.count))
    print(String(format: "first correct word after speech onset: median %.0f ms, p95 %.0f ms (%d of %d clips)", percentile(fc, 0.5), percentile(fc, 0.95), fc.count, results.count))
    let ch = results.map { Double($0.changedWords) }, se = results.map { Double($0.settledChanges) }
    let finalWords = results.reduce(0) { $0 + $1.finalWords }
    print(String(format: "shown words later changed per clip: median %.0f, mean %.1f; excluding the last two words of each pass: median %.0f, mean %.1f; per 100 final words %.1f / %.1f",
                 percentile(ch, 0.5), ch.reduce(0, +) / Double(max(ch.count, 1)), percentile(se, 0.5), se.reduce(0, +) / Double(max(se.count, 1)),
                 ch.reduce(0, +) * 100 / Double(max(finalWords, 1)), se.reduce(0, +) * 100 / Double(max(finalWords, 1))))
    if totalWords > 0 { print(String(format: "final-pass corpus WER %.2f%%", Double(totalErrors) / Double(totalWords) * 100)) }
    if let jsonPath {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: URL(fileURLWithPath: jsonPath))
    }
}

/// `lsbench fillers --engine <spec> [--out file.jsonl] <audio or folder>...`: one JSON line per clip with the
/// engine's transcript and the fillers `CoachText.analyse` finds in it (the Speech Coach's rules).
func runFillerBench(_ arguments: [String]) async throws {
    var args = arguments
    func option(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        defer { args.removeSubrange(i...(i + 1)) }
        return args[i + 1]
    }
    guard let spec = option("--engine") else { throw BenchError.usage("usage: lsbench fillers --engine <spec> [--out file.jsonl] <audio or folder>...") }
    let outPath = option("--out")
    let files = audioFiles(in: args)
    guard !files.isEmpty else { throw BenchError.usage("no audio files") }
    let converter = AudioConverter()
    let engine = try makeEngine(spec, cohereChunkSeconds: nil)
    let first = try converter.resampleAudioFile(files[0])
    try await engine.load(warmup: Array(first.prefix(16_000 * 3)))

    struct Line: Codable { let clip: String; let seconds: Double; let words: Int; let fillers: [String]; let latencyMs: Double; let text: String }
    var lines: [Line] = []
    var totalFillers = 0, totalWords = 0
    for url in files {
        let samples = try converter.resampleAudioFile(url)
        let start = ContinuousClock.now
        let text = try await engine.transcribe(samples).trimmingCharacters(in: .whitespacesAndNewlines)
        let ms = (ContinuousClock.now - start).seconds * 1000
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let found = CoachText.analyse(words).fillers.map { "\(words[$0.index].trimmingCharacters(in: .punctuationCharacters).lowercased())@\($0.index)" }
        totalFillers += found.count; totalWords += words.count
        lines.append(Line(clip: url.deletingPathExtension().lastPathComponent, seconds: Double(samples.count) / 16_000, words: words.count, fillers: found, latencyMs: ms, text: text))
        print(String(format: "%@ %6.1fs %4d words %2d fillers %@", url.lastPathComponent.padding(toLength: 28, withPad: " ", startingAt: 0), Double(samples.count) / 16_000, words.count, found.count, found.joined(separator: " ")))
    }
    print("\n\(engine.name): \(files.count) clips, \(totalWords) words, \(totalFillers) fillers")
    if let outPath {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try lines.map { String(data: try encoder.encode($0), encoding: .utf8)! }.joined(separator: "\n") + "\n"
        try data.write(to: URL(fileURLWithPath: outPath), atomically: true, encoding: .utf8)
    }
}
