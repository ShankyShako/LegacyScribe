@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import HexCore
import Speech

/// `lsbench live --engine apple --stream [--fast] [--speed 1] [--early] [--json out.json] <audio or folder>...`
///
/// Apple's real streaming: a `SpeechTranscriber` with `.volatileResults` (and `.fastResults` with `--fast`)
/// gets the clip as 100 ms `AnalyzerInput` buffers fed in real time (`--speed N` feeds N times faster: a smoke
/// test only, its times are not comparable). The caption at any moment is every finalized result so far plus
/// the newest volatile one. Each result is stamped with the wall time since the first buffer, which at 1x is
/// the audio time. Three displays are scored on the same events: `raw` (finalized + volatile), `settled2`
/// (volatile words except the last two) and `stable2` (volatile words that the previous update also had, as a
/// prefix). Besides the prefix mode's columns it reports how late finalized words arrive (arrival time minus the
/// end of their `audioTimeRange`) and how far volatile text runs ahead of the finalized text.
/// `--early` also prints when `SuperTrigger.earlyVerdict` first says isSuper on the displayed text.
func runLiveStreamBench(_ arguments: [String]) async throws {
    var args = arguments
    func option(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        defer { args.removeSubrange(i...(i + 1)) }
        return args[i + 1]
    }
    func flag(_ name: String) -> Bool {
        guard let i = args.firstIndex(of: name) else { return false }
        args.remove(at: i)
        return true
    }
    guard option("--engine") == "apple" else { throw BenchError.usage("lsbench live --stream only supports --engine apple") }
    _ = flag("--stream")
    if flag("--rescore") {
        // `--rescore a.json b.json`: score the confidence displays again from the stored result lists, no rerun.
        for path in args {
            let clips = try JSONDecoder().decode([ConfClip].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            analyzeConfidence(label: path, clips: clips)
        }
        return
    }
    let fast = flag("--fast")
    let confidence = flag("--confidence")
    let early = flag("--early")
    let speed = option("--speed").flatMap(Double.init) ?? 1
    let jsonPath = option("--json")
    let files = audioFiles(in: args)
    guard !files.isEmpty else { throw BenchError.usage("no audio files") }

    if !(await AppleSpeech.isInstalled()) {
        FileHandle.standardError.write("installing Apple's English speech model…\n".data(using: .utf8)!)
        try await AppleSpeech.install { _ in }
    }
    let converter = AudioConverter()
    let clips = try files.map { url -> (name: String, samples: [Float], reference: String?) in
        let reference = try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
        return (url.deletingPathExtension().lastPathComponent, try converter.resampleAudioFile(url), reference)
    }
    let label = "apple stream volatile" + (fast ? "+fast" : "") + (speed == 1 ? "" : String(format: " (%.0fx feed)", speed))
    FileHandle.standardError.write("warming up \(label)…\n".data(using: .utf8)!)
    _ = try await streamClip(Array(clips[0].samples.prefix(16_000 * 3)), fast: fast, confidence: confidence, speed: 20)

    struct Variant: Codable {
        let name: String
        let firstWordMs: Double?          // from speech onset
        let firstWordFromStartMs: Double? // from clip start
        let firstCorrectMs: Double?       // from speech onset
        let updates: Int                  // display changes
        let changedPerEvent: Int          // between consecutive result events
        let settledPerEvent: Int
        let changedAt400: Int             // display sampled every 0.4 s, like the prefix mode's passes
        let settledAt400: Int
        let textBeforeOnset: String?
        let firstSuperMs: Double?         // clip start, `--early`
        let superAtHeads: [Bool]?         // at 1.0 / 1.7 / 2.5 / 3.3 s
    }
    struct ClipResult: Codable {
        let clip: String; let seconds: Double; let onset: Double
        let events: Int; let finalEvents: Int; let bursts: Int
        let finalWER: Double?; let finalWords: Int
        let finishDelayMs: Double          // last buffer fed -> results complete
        let finalLagMs: [Double]           // per finalized word
        let volatileLagMs: [Double]        // per volatile update: arrival - end of the result's audio range
        let volatileAheadSeconds: [Double] // per volatile update: end of volatile text - end of finalized text
        let volatileAheadWords: [Int]
        let variants: [Variant]
        let finalText: String
        let reference: String?
        let records: [ResultRecord]?       // `--confidence`: every result's words with confidence
    }
    let headTimes = [1.0, 1.7, 2.5, 3.3]
    var results: [ClipResult] = []
    var totalErrors = 0, totalWords = 0

    for clip in clips {
        let duration = Double(clip.samples.count) / 16_000
        let onset = speechOnset(clip.samples)
        let run = try await streamClip(clip.samples, fast: fast, confidence: confidence, speed: speed)
        let refWords = clip.reference.map { WER.normalize($0) } ?? []

        // Replay the events into displays.
        var finalized: [String] = []
        var finalEnd = 0.0
        var volatile: StreamEvent?
        var previousVolatileWords: [String] = []
        var displays: [String: [(t: Double, text: String)]] = ["raw": [], "settled2": [], "stable2": []]
        var lags: [Double] = [], vLags: [Double] = [], aheadS: [Double] = [], aheadW: [Int] = []
        for (index, event) in run.events.enumerated() {
            let t = event.t * speed // audio time; equals wall time at 1x
            // Results arrive in bursts (several growing texts at the same instant); a caption shows only the last.
            let visible = index + 1 == run.events.count || run.events[index + 1].t - event.t >= 0.01
            if event.isFinal {
                finalized.append(event.text)
                finalEnd = max(finalEnd, event.end)
                for w in event.words { lags.append((event.t - w.end / speed) * 1000) }
                if let v = volatile, v.start < event.end - 0.01 { volatile = nil; previousVolatileWords = [] }
            } else {
                volatile = event
                let words = event.words.map(\.word)
                if visible {
                    vLags.append((event.t - event.end / speed) * 1000)
                    aheadS.append(max(0, event.end - finalEnd))
                    aheadW.append(words.count)
                }
            }
            let volatileWords = volatile?.text.split(whereSeparator: \.isWhitespace).map(String.init) ?? []
            var common = 0
            while common < min(volatileWords.count, previousVolatileWords.count), volatileWords[common] == previousVolatileWords[common] { common += 1 }
            if !event.isFinal { previousVolatileWords = volatileWords }
            func caption(_ tail: ArraySlice<String>) -> String {
                (finalized + (tail.isEmpty ? [] : [tail.joined(separator: " ")]))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
            }
            guard visible else { continue }
            displays["raw"]!.append((t, caption(volatileWords[...])))
            displays["settled2"]!.append((t, caption(volatileWords.dropLast(2))))
            displays["stable2"]!.append((t, caption(volatileWords.prefix(common))))
        }
        let finalText = finalized.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
        let wer = clip.reference.map { WER.compute(reference: $0, hypothesis: finalText) }
        if let wer { totalErrors += wer.substitutions + wer.deletions + wer.insertions; totalWords += wer.referenceWords }

        func textAt(_ list: [(t: Double, text: String)], _ time: Double) -> String {
            var text = ""
            for d in list { if d.t <= time { text = d.text } else { break } }
            return text
        }
        var variants: [Variant] = []
        for name in ["raw", "settled2", "stable2"] {
            let list = displays[name]!
            var firstWord: Double?, firstCorrect: Double?, updates = 0, last = ""
            var changed = 0, settled = 0
            var before: String?
            for (i, d) in list.enumerated() {
                let words = WER.normalize(d.text)
                if firstWord == nil, !words.isEmpty { firstWord = d.t }
                if firstCorrect == nil, let r = refWords.first, words.first == r { firstCorrect = d.t }
                if d.text != last { updates += 1; last = d.text }
                if d.t < onset, !words.isEmpty { before = d.text }
                if i > 0 {
                    let c = changedWords(old: WER.normalize(list[i - 1].text), new: words)
                    changed += c.changed; settled += c.settled
                }
            }
            // The display sampled every 0.4 s, as the prefix mode's passes.
            var changed400 = 0, settled400 = 0
            var previousWords: [String] = []
            var tick = 0.4
            var ticks: [Double] = []
            while tick < duration - 0.05 { ticks.append(tick); tick += 0.4 }
            ticks.append(duration)
            for tk in ticks {
                let words = WER.normalize(textAt(list, tk))
                let c = changedWords(old: previousWords, new: words)
                changed400 += c.changed; settled400 += c.settled
                previousWords = words
            }
            var firstSuper: Double?, superHeads: [Bool]?
            if early {
                for d in list where SuperTrigger.earlyVerdict(d.text).isSuper == true { firstSuper = d.t; break }
                superHeads = headTimes.map { SuperTrigger.earlyVerdict(textAt(list, $0)).isSuper == true }
            }
            variants.append(Variant(name: name, firstWordMs: firstWord.map { ($0 - onset) * 1000 },
                                    firstWordFromStartMs: firstWord.map { $0 * 1000 },
                                    firstCorrectMs: firstCorrect.map { ($0 - onset) * 1000 },
                                    updates: updates, changedPerEvent: changed, settledPerEvent: settled,
                                    changedAt400: changed400, settledAt400: settled400,
                                    textBeforeOnset: before, firstSuperMs: firstSuper.map { $0 * 1000 }, superAtHeads: superHeads))
        }
        let result = ClipResult(clip: clip.name, seconds: duration, onset: onset, events: run.events.count,
                                finalEvents: run.events.filter(\.isFinal).count, bursts: displays["raw"]!.count, finalWER: wer?.rate,
                                finalWords: WER.normalize(finalText).count, finishDelayMs: run.finishDelay * 1000,
                                finalLagMs: lags, volatileLagMs: vLags, volatileAheadSeconds: aheadS, volatileAheadWords: aheadW,
                                variants: variants, finalText: finalText, reference: clip.reference,
                                records: confidence ? run.events.enumerated().map { index, event in
                                    ResultRecord(t: event.t * speed, isFinal: event.isFinal, start: event.start, end: event.end,
                                                 visible: index + 1 == run.events.count || run.events[index + 1].t - event.t >= 0.01,
                                                 words: event.tokens)
                                } : nil)
        results.append(result)
        let raw = variants[0], s2 = variants[1], st = variants[2]
        func ms(_ v: Double?) -> String { v.map { String(format: "%5.0f", $0) } ?? "  n/a" }
        print(String(format: "%@ %5.1fs  %3d events (%2d final)  first word %@/%@/%@  first correct %@/%@/%@  changed@0.4 %3d/%3d/%3d  settled %3d/%3d/%3d  of %3d words  WER %@  finish +%.0f ms%@",
                     clip.name.padding(toLength: 20, withPad: " ", startingAt: 0), duration, result.events, result.finalEvents,
                     ms(raw.firstWordMs), ms(s2.firstWordMs), ms(st.firstWordMs), ms(raw.firstCorrectMs), ms(s2.firstCorrectMs), ms(st.firstCorrectMs),
                     raw.changedAt400, s2.changedAt400, st.changedAt400, raw.settledAt400, s2.settledAt400, st.settledAt400,
                     result.finalWords, wer.map { String(format: "%.1f%%", $0.rate * 100) } ?? "n/a", result.finishDelayMs,
                     raw.textBeforeOnset.map { "  BEFORE ONSET: \"\($0)\"" } ?? ""))
    }

    print("\n\(label): \(results.count) clips, \(results.reduce(0) { $0 + $1.events }) result events (\(results.reduce(0) { $0 + $1.finalEvents }) final), \(results.reduce(0) { $0 + $1.bursts }) bursts")
    for index in 0 ..< 3 {
        let name = results[0].variants[index].name
        let v = results.map { $0.variants[index] }
        let fw = v.compactMap(\.firstWordMs), fs = v.compactMap(\.firstWordFromStartMs), fc = v.compactMap(\.firstCorrectMs)
        let ch = v.map { Double($0.changedAt400) }, se = v.map { Double($0.settledAt400) }
        let cp = v.map { Double($0.changedPerEvent) }, sp = v.map { Double($0.settledPerEvent) }
        let words = results.reduce(0) { $0 + $1.finalWords }
        func mean(_ a: [Double]) -> Double { a.reduce(0, +) / Double(max(a.count, 1)) }
        print("--- display \(name)")
        print(String(format: "first word: from clip start median %.0f ms; after onset median %.0f ms, p95 %.0f ms (%d of %d clips)", percentile(fs, 0.5), percentile(fw, 0.5), percentile(fw, 0.95), fw.count, results.count))
        print(String(format: "first correct word after onset: median %.0f ms, p95 %.0f ms (%d of %d clips)", percentile(fc, 0.5), percentile(fc, 0.95), fc.count, results.count))
        print(String(format: "shown words later changed per clip (display every 0.4 s): median %.0f, mean %.1f; settled median %.0f, mean %.1f; per 100 final words %.1f / %.1f",
                     percentile(ch, 0.5), mean(ch), percentile(se, 0.5), mean(se), mean(ch) * Double(results.count) * 100 / Double(max(words, 1)), mean(se) * Double(results.count) * 100 / Double(max(words, 1))))
        print(String(format: "  between every result event: median %.0f, mean %.1f; settled median %.0f, mean %.1f; display changes per clip median %.0f", percentile(cp, 0.5), mean(cp), percentile(sp, 0.5), mean(sp), percentile(v.map { Double($0.updates) }, 0.5)))
        if early {
            let fsup = v.compactMap(\.firstSuperMs)
            let heads = (0 ..< 4).map { h in v.filter { $0.superAtHeads?[h] == true }.count }
            print(String(format: "isSuper first at (clip start): median %.0f ms, p95 %.0f ms (%d of %d clips); isSuper at 1.0/1.7/2.5/3.3 s: %d / %d / %d / %d", percentile(fsup, 0.5), percentile(fsup, 0.95), fsup.count, v.count, heads[0], heads[1], heads[2], heads[3]))
        }
    }
    let lag = results.flatMap(\.finalLagMs), vlag = results.flatMap(\.volatileLagMs)
    let aheadS = results.flatMap(\.volatileAheadSeconds), aheadW = results.flatMap { $0.volatileAheadWords.map(Double.init) }
    print(String(format: "finalized word lag (arrival - word end): median %.0f ms, p95 %.0f ms, max %.0f ms (%d words)", percentile(lag, 0.5), percentile(lag, 0.95), lag.max() ?? 0, lag.count))
    print(String(format: "volatile lag (arrival - end of the result's audio range): median %.0f ms, p95 %.0f ms (%d updates)", percentile(vlag, 0.5), percentile(vlag, 0.95), vlag.count))
    print(String(format: "volatile text ahead of finalized: median %.1f s / %.0f words, p95 %.1f s / %.0f words, max %.1f s", percentile(aheadS, 0.5), percentile(aheadW, 0.5), percentile(aheadS, 0.95), percentile(aheadW, 0.95), aheadS.max() ?? 0))
    let finish = results.map(\.finishDelayMs)
    print(String(format: "after the last buffer, results complete: median %.0f ms, p95 %.0f ms", percentile(finish, 0.5), percentile(finish, 0.95)))
    if totalWords > 0 { print(String(format: "final text corpus WER %.2f%%", Double(totalErrors) / Double(totalWords) * 100)) }
    let beforeClips = results.filter { $0.variants[0].textBeforeOnset != nil }
    print("text shown before speech onset (raw): \(beforeClips.count) of \(results.count) clips" + beforeClips.map { "\n  \($0.clip): \"\($0.variants[0].textBeforeOnset!)\"" }.joined())
    if confidence {
        analyzeConfidence(label: label, clips: results.map {
            ConfClip(clip: $0.clip, seconds: $0.seconds, onset: $0.onset, finalWords: $0.finalWords, reference: $0.reference, records: $0.records ?? [])
        })
    }
    if let jsonPath {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: URL(fileURLWithPath: jsonPath))
    }
}

struct StreamEvent: Sendable {
    let t: Double          // seconds since the first buffer was fed
    let isFinal: Bool
    let text: String
    let start: Double      // result range, seconds of audio
    let end: Double
    let words: [(word: String, end: Double)]
    var tokens: [ConfToken] = []   // whitespace tokens of the text with their transcriptionConfidence (`--confidence`)
}

/// Feeds `samples` (16 kHz mono) to a fresh analyzer in 100 ms buffers at `speed`x real time.
private func streamClip(_ samples: [Float], fast: Bool, confidence: Bool, speed: Double) async throws -> (events: [StreamEvent], finishDelay: Double) {
    var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
    if fast { reporting.insert(.fastResults) }
    let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), transcriptionOptions: [], reportingOptions: reporting, attributeOptions: confidence ? [.audioTimeRange, .transcriptionConfidence] : [.audioTimeRange])
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
          let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
          let sourceBuffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
          let converter = AVAudioConverter(from: source, to: format)
    else { throw BenchError.usage("no audio format for SpeechAnalyzer") }
    sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { sourceBuffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    let convertedCapacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / 16_000) + 4_096
    guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: convertedCapacity) else { throw BenchError.usage("buffer") }
    nonisolated(unsafe) var supplied = false
    var conversionError: NSError?
    converter.convert(to: converted, error: &conversionError) { _, status in
        if supplied { status.pointee = .endOfStream; return nil }
        supplied = true; status.pointee = .haveData; return sourceBuffer
    }
    if let conversionError { throw conversionError }

    trace("format \(format)")
    try await analyzer.prepareToAnalyze(in: format)
    trace("prepared")
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    struct Stamped: Sendable { let at: ContinuousClock.Instant; let event: StreamEvent }
    let collector = Task { () throws -> [Stamped] in
        var out: [Stamped] = []
        for try await result in transcriber.results {
            let now = ContinuousClock.now
            var words: [(word: String, end: Double)] = []
            for run in result.text.runs {
                guard let range = run.audioTimeRange else { continue }
                let pieces = String(result.text[run.range].characters).split(whereSeparator: \.isWhitespace).map(String.init)
                guard !pieces.isEmpty else { continue }
                let start = range.start.seconds, step = range.duration.seconds / Double(pieces.count)
                for (i, piece) in pieces.enumerated() { words.append((piece, start + Double(i + 1) * step)) }
            }
            // Whitespace tokens of the text; a token's confidence is the lowest of the runs its characters sit in.
            var tokens: [ConfToken] = []
            if confidence {
                var current = "", currentConfidence: Double?
                func flush() {
                    if !current.isEmpty { tokens.append(ConfToken(w: current, c: currentConfidence)); current = ""; currentConfidence = nil }
                }
                for run in result.text.runs {
                    let c = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
                    for ch in result.text[run.range].characters {
                        if ch.isWhitespace { flush() } else {
                            current.append(ch)
                            if let c { currentConfidence = min(currentConfidence ?? c, c) }
                        }
                    }
                }
                flush()
            }
            let range = result.range
            trace("result final=\(result.isFinal) range=\(range.start.seconds)-\(range.end.seconds) text=\(String(result.text.characters))")
            out.append(Stamped(at: now, event: StreamEvent(t: 0, isFinal: result.isFinal, text: String(result.text.characters),
                                         start: range.start.seconds, end: range.end.seconds, words: words, tokens: tokens)))
        }
        return out
    }
    try await analyzer.start(inputSequence: stream)
    trace("started")

    let chunk = Int(format.sampleRate / 10)
    let total = Int(converted.frameLength)
    let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
    let clock = ContinuousClock()
    let producer = Task { () -> ContinuousClock.Instant in
        let t0 = clock.now
        var index = 0, offset = 0
        while offset < total {
            let count = min(chunk, total - offset)
            if let piece = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) {
                piece.frameLength = AVAudioFrameCount(count)
                let from = UnsafeRawPointer(converted.audioBufferList.pointee.mBuffers.mData!).advanced(by: offset * bytesPerFrame)
                memcpy(piece.audioBufferList.pointee.mBuffers.mData!, from, count * bytesPerFrame)
                continuation.yield(AnalyzerInput(buffer: piece))
            }
            index += 1; offset += count
            let target = t0 + .seconds(Double(index) * 0.1 / speed)
            try? await clock.sleep(until: target)
        }
        continuation.finish()
        return t0
    }
    let t0 = await producer.value
    trace("fed")
    let fedAt = clock.now
    let end = CMTime(value: CMTimeValue(total - 160), timescale: CMTimeScale(format.sampleRate))
    try await analyzer.finalizeAndFinish(through: end)
    trace("finalized")
    let raw = try await collector.value
    let doneAt = clock.now
    let events = raw.map { pair in
        StreamEvent(t: (pair.at - t0).seconds, isFinal: pair.event.isFinal, text: pair.event.text,
                    start: pair.event.start, end: pair.event.end, words: pair.event.words, tokens: pair.event.tokens)
    }
    return (events, (doneAt - fedAt).seconds)
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

private func trace(_ message: String) {
    if ProcessInfo.processInfo.environment["LSBENCH_TRACE"] != nil { FileHandle.standardError.write("[stream] \(message)\n".data(using: .utf8)!) }
}

// MARK: - Confidence (`--confidence`, `--rescore`)

struct ConfToken: Codable, Sendable { let w: String; let c: Double? }
struct ResultRecord: Codable, Sendable {
    let t: Double          // audio time the result arrived
    let isFinal: Bool
    let start: Double
    let end: Double
    let visible: Bool      // last result of a burst (a caption only shows that one)
    let words: [ConfToken]
}
/// What the confidence scoring needs from a clip; decodes from the stream bench's JSON (extra keys ignored).
struct ConfClip: Codable {
    let clip: String; let seconds: Double; let onset: Double; let finalWords: Int
    let reference: String?
    let records: [ResultRecord]
}

private struct DWord { let w: String; let c: Double?; let isFinal: Bool }
private enum Tier { case solid, dim }
private struct Snapshot { let t: Double; let finalized: [DWord]; let volatile: [DWord]; let stable: Int }

private func dwords(_ tokens: [ConfToken], final: Bool) -> [DWord] {
    tokens.flatMap { token in WER.normalize(token.w).map { DWord(w: $0, c: token.c, isFinal: final) } }
}

/// The captions a user would see: one snapshot per visible result. `stable` = leading volatile words that the
/// previous update (any result, not only visible ones: the same rule as stable-2 above) also had.
private func replay(_ records: [ResultRecord]) -> [Snapshot] {
    var finalized: [DWord] = []
    var volatile: ResultRecord?
    var previous: [String] = []
    var out: [Snapshot] = []
    for rec in records {
        if rec.isFinal {
            finalized += dwords(rec.words, final: true)
            if let v = volatile, v.start < rec.end - 0.01 { volatile = nil; previous = [] }
        } else {
            volatile = rec
        }
        let vw = volatile.map { dwords($0.words, final: false) } ?? []
        var common = 0
        while common < min(vw.count, previous.count), vw[common].w == previous[common] { common += 1 }
        if !rec.isFinal { previous = vw.map(\.w) }
        guard rec.visible else { continue }
        out.append(Snapshot(t: rec.t, finalized: finalized, volatile: vw, stable: common))
    }
    return out
}

/// Same alignment as `changedWords`, per word: true = kept as the same word in `new`.
private func keptFlags(old: [String], new: [String]) -> [Bool] {
    let n = old.count, m = new.count
    guard n > 0 else { return [] }
    var cost = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    for i in 0 ... n { cost[i][0] = i }
    for j in 0 ... m { cost[0][j] = j }
    if m > 0 {
        for i in 1 ... n { for j in 1 ... m {
            cost[i][j] = min(cost[i - 1][j - 1] + (old[i - 1] == new[j - 1] ? 0 : 1), cost[i - 1][j] + 1, cost[i][j - 1] + 1)
        } }
    }
    var kept = [Bool](repeating: false, count: n)
    var i = n, j = m
    while i > 0 && j > 0 {
        if old[i - 1] == new[j - 1], cost[i][j] == cost[i - 1][j - 1] { kept[i - 1] = true; i -= 1; j -= 1 }
        else if cost[i][j] == cost[i - 1][j - 1] + 1 { i -= 1; j -= 1 }
        else if cost[i][j] == cost[i - 1][j] + 1 { i -= 1 }
        else { j -= 1 }
    }
    return kept
}

private struct DisplayConfig {
    enum Rule { case threshold(Double), lastTwo }
    let name: String
    let solidB: Bool       // false: solid = finalized only (A); true: finalized or stable (B)
    let rule: Rule
}

/// Solid words first, then dim ones; the first volatile word that fails the rule hides itself and all after it.
private func tiers(_ snap: Snapshot, _ config: DisplayConfig) -> [(w: String, tier: Tier)] {
    var out = snap.finalized.map { (w: $0.w, tier: Tier.solid) }
    let solidCount = config.solidB ? snap.stable : 0
    for (i, d) in snap.volatile.enumerated() {
        if i < solidCount { out.append((d.w, .solid)); continue }
        switch config.rule {
        case .threshold(let t):
            if (d.c ?? -1) >= t { out.append((d.w, .dim)) } else { return out }
        case .lastTwo:
            if i >= snap.volatile.count - 2 { out.append((d.w, .dim)) } else { return out }
        }
    }
    return out
}

func analyzeConfidence(label: String, clips: [ConfClip]) {
    func mean(_ a: [Double]) -> Double { a.reduce(0, +) / Double(max(a.count, 1)) }
    func pct(_ part: Int, _ whole: Int) -> String { whole == 0 ? "n/a" : String(format: "%.1f%%", Double(part) * 100 / Double(whole)) }
    let snaps = clips.map { replay($0.records) }
    let finalWords = clips.reduce(0) { $0 + $1.finalWords }
    print("\n=== confidence: \(label): \(clips.count) clips, \(finalWords) final words")

    // 1. Does confidence exist, and what does it look like?
    var volatileWordsAll: [DWord] = [], finalWordsAll: [DWord] = []
    for clip in clips { for rec in clip.records {
        if rec.isFinal { finalWordsAll += dwords(rec.words, final: true) } else { volatileWordsAll += dwords(rec.words, final: false) }
    } }
    func distribution(_ name: String, _ words: [DWord]) {
        let cs = words.compactMap(\.c)
        let distinct = Set(cs.map { ($0 * 1000).rounded() }).count
        print(String(format: "%@: %d words in results, %d with confidence (%@), %d distinct values; min %.2f p10 %.2f p25 %.2f median %.2f p75 %.2f p90 %.2f max %.2f",
                     name, words.count, cs.count, pct(cs.count, words.count), distinct,
                     cs.min() ?? 0, percentile(cs, 0.1), percentile(cs, 0.25), percentile(cs, 0.5), percentile(cs, 0.75), percentile(cs, 0.9), cs.max() ?? 0))
        let edges: [(String, Double, Double)] = [("<0.3", -1, 0.3), ("0.3-0.5", 0.3, 0.5), ("0.5-0.7", 0.5, 0.7), ("0.7-0.9", 0.7, 0.9), (">=0.9", 0.9, 9)]
        print("  buckets: " + edges.map { e in "\(e.0) " + pct(cs.filter { $0 >= e.1 && $0 < e.2 }.count, cs.count) }.joined(separator: ", ")
              + ", none " + pct(words.count - cs.count, words.count))
    }
    distribution("volatile results", volatileWordsAll)
    distribution("final results", finalWordsAll)
    if volatileWordsAll.compactMap(\.c).isEmpty {
        print("NO CONFIDENCE ON VOLATILE RESULTS: scoring only the B-solid + dim-last-two display")
    }

    // 2. Does confidence predict change? Each volatile word shown at one visible update, judged by the next one.
    let bucketNames = ["<0.3", "0.3-0.5", "0.5-0.7", "0.7-0.9", ">=0.9", "none"]
    func bucket(_ c: Double?) -> Int {
        guard let c else { return 5 }
        return c < 0.3 ? 0 : c < 0.5 ? 1 : c < 0.7 ? 2 : c < 0.9 ? 3 : 4
    }
    // [bucket][position 0 last, 1 second last, 2 deeper] -> (shown, changed)
    var shown = [[Int]](repeating: [0, 0, 0], count: 6), changed = shown
    for clipSnaps in snaps {
        for k in 1 ..< max(clipSnaps.count, 1) {
            let old = clipSnaps[k - 1], new = clipSnaps[k]
            let oldWords = (old.finalized + old.volatile).map(\.w), newWords = (new.finalized + new.volatile).map(\.w)
            let kept = keptFlags(old: oldWords, new: newWords)
            for (i, d) in old.volatile.enumerated() {
                let fromEnd = old.volatile.count - 1 - i
                let pos = min(fromEnd, 2), b = bucket(d.c)
                shown[b][pos] += 1
                if !kept[old.finalized.count + i] { changed[b][pos] += 1 }
            }
        }
    }
    print("change rate of a volatile word at the next visible update, by confidence bucket and position from the end (changed / shown):")
    print("| Confidence | last | 2nd last | deeper | all |")
    for b in 0 ..< 6 {
        let all = shown[b].reduce(0, +), allC = changed[b].reduce(0, +)
        if all == 0 { continue }
        print("| \(bucketNames[b]) | " + (0 ..< 3).map { "\(pct(changed[b][$0], shown[b][$0])) (\(changed[b][$0])/\(shown[b][$0]))" }.joined(separator: " | ") + " | \(pct(allC, all)) (\(allC)/\(all)) |")
    }
    let totalShown = (0 ..< 3).map { p in shown.reduce(0) { $0 + $1[p] } }, totalChanged = (0 ..< 3).map { p in changed.reduce(0) { $0 + $1[p] } }
    print("| all | " + (0 ..< 3).map { "\(pct(totalChanged[$0], totalShown[$0])) (\(totalChanged[$0])/\(totalShown[$0]))" }.joined(separator: " | ")
          + " | \(pct(totalChanged.reduce(0, +), totalShown.reduce(0, +))) |")

    // 3. Three-tier displays, scored on the display sampled every 0.4 s.
    var configs: [DisplayConfig] = [DisplayConfig(name: "B + dim last two", solidB: true, rule: .lastTwo)]
    if volatileWordsAll.compactMap(\.c).isEmpty {
        // No confidence to threshold: show every volatile word, the ones not yet solid dimmed (how much sits dim).
        configs.append(DisplayConfig(name: "A, every volatile word dim", solidB: false, rule: .threshold(-1)))
        configs.append(DisplayConfig(name: "B, every other volatile word dim", solidB: true, rule: .threshold(-1)))
    } else {
        for solidB in [false, true] { for t in [0.0, 0.3, 0.5, 0.7, 0.9] {
            configs.append(DisplayConfig(name: "\(solidB ? "B" : "A") T=\(t == 0 ? "0 (none hidden)" : String(t))", solidB: solidB, rule: .threshold(t)))
        } }
    }
    print("\n| Display | First word, from onset (median / p95) | First correct word, from onset (median / p95) | Changed per 100 words | Settled per 100 words | Dim share of shown words (median / mean) | Dim, later changed | Solid, later changed |")
    for config in configs {
        var fw: [Double] = [], fc: [Double] = []
        var changedTotal = 0, settledTotal = 0, dimChanged = 0, solidChanged = 0
        var shares: [Double] = []
        var correctClips = 0
        for (ci, clip) in clips.enumerated() {
            let refFirst = clip.reference.map { WER.normalize($0) }?.first
            let displays = snaps[ci].map { (t: $0.t, words: tiers($0, config)) }
            if let first = displays.first(where: { !$0.words.isEmpty }) { fw.append((first.t - clip.onset) * 1000) }
            if let refFirst, let first = displays.first(where: { $0.words.first?.w == refFirst }) { fc.append((first.t - clip.onset) * 1000); correctClips += 1 }
            var ticks: [Double] = []
            var tick = 0.4
            while tick < clip.seconds - 0.05 { ticks.append(tick); tick += 0.4 }
            ticks.append(clip.seconds)
            var previous: [(w: String, tier: Tier)] = []
            for tk in ticks {
                var current: [(w: String, tier: Tier)] = []
                for d in displays { if d.t <= tk { current = d.words } else { break } }
                if !previous.isEmpty {
                    let kept = keptFlags(old: previous.map(\.w), new: current.map(\.w))
                    for (i, p) in previous.enumerated() where !kept[i] {
                        changedTotal += 1
                        if i < previous.count - 2 { settledTotal += 1 }
                        if p.tier == .dim { dimChanged += 1 } else { solidChanged += 1 }
                    }
                }
                if !current.isEmpty { shares.append(Double(current.filter { $0.tier == .dim }.count) / Double(current.count)) }
                previous = current
            }
        }
        let per100 = { (n: Int) in Double(n) * 100 / Double(max(finalWords, 1)) }
        print(String(format: "| %@ | %.0f / %.0f ms | %.0f / %.0f ms (%d of %d) | %d (%.1f) | %d (%.1f) | %.0f%% / %.0f%% | %d | %d |",
                     config.name, percentile(fw, 0.5), percentile(fw, 0.95), percentile(fc, 0.5), percentile(fc, 0.95), correctClips, clips.count,
                     changedTotal, per100(changedTotal), settledTotal, per100(settledTotal),
                     percentile(shares, 0.5) * 100, mean(shares) * 100, dimChanged, solidChanged))
    }
}
