import AVFAudio
import FluidAudio
import Foundation
import HexCore

/// `lsbench align --tts <practice_lines.json> [count]` measures word timings against exact boundaries (see
/// `runSyntheticAlignBench`). `lsbench align <wav or folder>...` only compares the CTC aligner with Parakeet
/// TDT on real recordings; TDT's step-quantized timings are no ground truth, so read it as agreement.
func runAlignBench(_ arguments: [String]) async throws {
    if arguments.first == "--tts" {
        try await runSyntheticAlignBench(Array(arguments.dropFirst()))
        return
    }
    let files = arguments.flatMap { path -> [URL] in
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [url] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { $0.hasSuffix(".wav") }.sorted().map { url.appendingPathComponent($0) }
    }
    guard !files.isEmpty else {
        print("usage: lsbench align <wav or folder>...")
        return
    }

    let modelsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LegacyScribe/Models/fluidaudio")
    let ctcDirectory = modelsRoot.appendingPathComponent(CtcModels.defaultCacheDirectory(for: .ctc110m).lastPathComponent)
    var loadStart = Date()
    try await CtcModels.download(to: ctcDirectory, variant: .ctc110m)
    let ctc = try await CtcModels.load(from: ctcDirectory, variant: .ctc110m)
    let tokenizer = try await CtcTokenizer.load(from: ctcDirectory)
    let spotter = CtcKeywordSpotter(models: ctc)
    let noTerms = CustomVocabularyContext(terms: [])
    print(String(format: "CTC 110M loaded in %.2f s", Date().timeIntervalSince(loadStart)))

    loadStart = Date()
    let tdtDirectory = modelsRoot.appendingPathComponent(AsrModels.defaultCacheDirectory(for: .v2).lastPathComponent)
    let tdt = AsrManager(config: .default, models: try await AsrModels.downloadAndLoad(to: tdtDirectory, version: .v2))
    print(String(format: "Parakeet TDT v2 loaded in %.2f s", Date().timeIntervalSince(loadStart)))

    // LSBENCH_LEAD overrides the aligner's start lead, to calibrate it.
    let lead = ProcessInfo.processInfo.environment["LSBENCH_LEAD"].flatMap(Double.init) ?? CTCWordAligner.defaultStartLead
    let converter = AudioConverter()
    var startErrors: [Double] = []
    var endErrors: [Double] = []
    var signedStarts: [Double] = []
    var signedEnds: [Double] = []
    var alignSeconds = 0.0
    var audioSeconds = 0.0
    var failures = 0
    for url in files {
        let samples = try converter.resampleAudioFile(url)
        audioSeconds += Double(samples.count) / 16_000
        var state = TdtDecoderState.make(decoderLayers: await tdt.decoderLayerCount)
        let result = try await tdt.transcribe(samples, decoderState: &state)
        let reference = tdtWords(from: result.tokenTimings ?? [])
        guard !reference.isEmpty else { continue }

        let start = Date()
        let emissions = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: noTerms)
        let aligned = CTCWordAligner.align(
            words: reference.map(\.word),
            logProbs: emissions.logProbs,
            frameDuration: emissions.frameDuration,
            blank: spotter.blankId,
            startLead: lead,
            tokenize: { tokenizer.encode($0) }
        )
        alignSeconds += Date().timeIntervalSince(start)
        guard let aligned else {
            failures += 1
            print("\(url.lastPathComponent): alignment failed")
            continue
        }
        if ProcessInfo.processInfo.environment["LSBENCH_WORDS"] != nil {
            print(String(format: "  frames %d x %.4f s = %.2f s for %.2f s of audio", emissions.logProbs.count, emissions.frameDuration,
                         Double(emissions.logProbs.count) * emissions.frameDuration, Double(samples.count) / 16_000))
            for (a, r) in zip(aligned, reference) {
                print(String(format: "  %-14@ tdt %6.2f-%6.2f  ctc %6.2f-%6.2f", r.word as NSString, r.start, r.end, a.start, a.end))
            }
        }
        let starts = zip(aligned, reference).map { abs($0.start - $1.start) }
        let ends = zip(aligned, reference).map { abs($0.end - $1.end) }
        startErrors += starts
        endErrors += ends
        signedStarts += zip(aligned, reference).map { $0.start - $1.start }
        signedEnds += zip(aligned, reference).map { $0.end - $1.end }
        print(String(format: "%@  %d words, start median %.0f ms, worst %.0f ms",
                     url.lastPathComponent, reference.count, median(starts) * 1000, (starts.max() ?? 0) * 1000))
    }

    guard !startErrors.isEmpty else { return }
    let within = Double(startErrors.filter { $0 <= 0.08 }.count) / Double(startErrors.count)
    print(String(
        format: "\n%d words in %d clips (%d failed). Word start vs TDT: median %.0f ms, p90 %.0f ms, %.0f%% within 80 ms. Word end: median %.0f ms, p90 %.0f ms.",
        startErrors.count, files.count, failures, median(startErrors) * 1000, percentile(startErrors, 0.9) * 1000, within * 100,
        median(endErrors) * 1000, percentile(endErrors, 0.9) * 1000
    ))
    print(String(format: "Signed (aligner minus TDT): start median %+.0f ms, end median %+.0f ms.",
                 percentile(signedStarts, 0.5) * 1000, percentile(signedEnds, 0.5) * 1000))
    print(String(format: "Alignment took %.0f ms per 10 s of audio.", alignSeconds / audioSeconds * 10_000))
}

/// TDT tokens grouped into words, as the app does it.
private func tdtWords(from tokens: [TokenTiming]) -> [SpokenWord] {
    WordMatcher.words(fromPieces: tokens.map { ($0.token, $0.startTime, $0.endTime) })
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

// MARK: - Synthetic ground truth

/// `lsbench align --tts <practice_lines.json> [count]`: each line built from words synthesized one at a
/// time (AVSpeechSynthesizer), silence-trimmed and joined with known gaps of 30–250 ms, so every word's
/// start and end are exact. Isolated words lack coarticulation, which makes boundaries harder to find, not
/// easier; it is still synthetic speech, so real voices will do somewhat worse.
func runSyntheticAlignBench(_ arguments: [String]) async throws {
    guard let path = arguments.first else {
        print("usage: lsbench align --tts <practice_lines.json> [count]")
        return
    }
    struct Lines: Decodable { struct Line: Decodable { var text: String }; var lines: [Line] }
    let lines = try JSONDecoder().decode(Lines.self, from: Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)))
    let count = arguments.dropFirst().first.flatMap(Int.init) ?? 60
    let lead = ProcessInfo.processInfo.environment["LSBENCH_LEAD"].flatMap(Double.init) ?? CTCWordAligner.defaultStartLead
    let variant: CtcModelVariant = ProcessInfo.processInfo.environment["LSBENCH_CTC"] == "0.6b" ? .ctc06b : .ctc110m
    let useCTC = ProcessInfo.processInfo.environment["LSBENCH_CTC"] != nil

    let modelsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LegacyScribe/Models/fluidaudio")
    let ctcDirectory = modelsRoot.appendingPathComponent(CtcModels.defaultCacheDirectory(for: variant).lastPathComponent)
    if useCTC { try await CtcModels.download(to: ctcDirectory, variant: variant) }
    let ctcModels = useCTC ? try await CtcModels.load(from: ctcDirectory, variant: variant) : nil
    let spotter = ctcModels.map { CtcKeywordSpotter(models: $0) }
    let tokenizer = useCTC ? try await CtcTokenizer.load(from: ctcDirectory) : nil
    let noTerms = CustomVocabularyContext(terms: [])

    // The app's method by default: Parakeet TDT v2's token timings moved onto the words (`WordMatcher`).
    // LSBENCH_CTC=110m or 0.6b times them with the CTC aligner instead.
    var tdt: AsrManager?
    if ProcessInfo.processInfo.environment["LSBENCH_CTC"] == nil {
        let tdtDirectory = modelsRoot.appendingPathComponent(AsrModels.defaultCacheDirectory(for: .v2).lastPathComponent)
        tdt = AsrManager(config: .default, models: try await AsrModels.downloadAndLoad(to: tdtDirectory, version: .v2))
    }
    var generator = SplitMix(seed: 42)
    var cache: [String: [Float]] = [:]
    var startErrors: [Double] = []
    var endErrors: [Double] = []
    for line in lines.lines.prefix(count) {
        let words = line.text.split(separator: " ").map(String.init)
        var samples = [Float](repeating: 0, count: 4_800)  // 0.3 s lead-in
        var truth: [SpokenWord] = []
        for word in words {
            let spoken = word.trimmingCharacters(in: .punctuationCharacters)
            if cache[spoken] == nil { cache[spoken] = trimSilence(try await synthesize(spoken)) }
            let clip = cache[spoken] ?? []
            let start = Double(samples.count) / 16_000
            samples += clip
            truth.append(SpokenWord(word: word, start: start, end: Double(samples.count) / 16_000))
            samples += [Float](repeating: 0, count: Int(16_000 * (0.03 + 0.22 * generator.unit())))
        }
        if let tdt {
            var state = TdtDecoderState.make(decoderLayers: await tdt.decoderLayerCount)
            let result = try await tdt.transcribe(samples, decoderState: &state)
            let heard = tdtWords(from: result.tokenTimings ?? [])
            let shift = ProcessInfo.processInfo.environment["LSBENCH_SHIFT"].flatMap(Double.init) ?? WordMatcher.tdtStartShift
            let timed = WordMatcher.transfer(heard, onto: words, startShift: shift)
            if ProcessInfo.processInfo.environment["LSBENCH_WORDS"] != nil {
                for (a, t) in zip(timed, truth) {
                    print(String(format: "  %-14@ truth %5.2f-%5.2f  tdt %5.2f-%5.2f", t.word as NSString, t.start, t.end, a.start, a.end))
                }
            }
            startErrors += zip(timed, truth).map { $0.start - $1.start }
            endErrors += zip(timed, truth).map { $0.end - $1.end }
            continue
        }
        guard let spotter, let tokenizer, let ctcModels else { continue }
        let emissions = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: noTerms)
        guard let aligned = CTCWordAligner.align(
            words: words, logProbs: emissions.logProbs, frameDuration: emissions.frameDuration,
            blank: spotter.blankId, startLead: lead, tokenize: { tokenizer.encode($0) }
        ) else { continue }
        if ProcessInfo.processInfo.environment["LSBENCH_WORDS"] != nil {
            let best = emissions.logProbs.map { row in row.indices.max(by: { row[$0] < row[$1] })! }
            let blankShare = Double(best.filter { $0 == spotter.blankId }.count) / Double(max(best.count, 1))
            var collapsed: [Int] = []
            for (i, id) in best.enumerated() where id != spotter.blankId && (i == 0 || best[i - 1] != id) { collapsed.append(id) }
            print(String(format: "  greedy (%.0f%% blank): ", blankShare * 100) + collapsed.compactMap { ctcModels.vocabulary[$0] }.joined().replacingOccurrences(of: "▁", with: " "))
            print(String(format: "  %d frames x %.4f s for %.2f s", emissions.logProbs.count, emissions.frameDuration, Double(samples.count) / 16_000))
            for (a, t) in zip(aligned, truth) {
                print(String(format: "  %-14@ truth %5.2f-%5.2f  ctc %5.2f-%5.2f", t.word as NSString, t.start, t.end, a.start, a.end))
            }
        }
        startErrors += zip(aligned, truth).map { $0.start - $1.start }
        endErrors += zip(aligned, truth).map { $0.end - $1.end }
    }
    func summary(_ signed: [Double]) -> String {
        let absolute = signed.map(abs)
        let within = Double(absolute.filter { $0 <= 0.08 }.count) / Double(max(absolute.count, 1))
        return String(format: "median %.0f ms off (signed %+.0f), p90 %.0f ms, %.0f%% within 80 ms",
                      percentile(absolute, 0.5) * 1000, percentile(signed, 0.5) * 1000, percentile(absolute, 0.9) * 1000, within * 100)
    }
    print(String(format: "%d words, lead %.0f ms. Start: %@. End: %@.", startErrors.count, lead * 1000, summary(startErrors), summary(endErrors)))
}

/// Deterministic gaps, so runs compare.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func unit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}

private func trimSilence(_ samples: [Float], threshold: Float = 0.01) -> [Float] {
    guard let first = samples.firstIndex(where: { abs($0) > threshold }),
          let last = samples.lastIndex(where: { abs($0) > threshold }) else { return [] }
    return Array(samples[first ... last])
}

/// 16 kHz mono samples of `text`.
private func synthesize(_ text: String) async throws -> [Float] {
    let synthesizer = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    final class Collected: @unchecked Sendable {
        var samples: [Float] = []
        var rate = 22_050.0
    }
    let collected = Collected()
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        var finished = false
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                if !finished { finished = true; done.resume() }
                return
            }
            collected.rate = pcm.format.sampleRate
            if let floats = pcm.floatChannelData?[0] {
                collected.samples += UnsafeBufferPointer(start: floats, count: Int(pcm.frameLength))
            } else if let ints = pcm.int16ChannelData?[0] {
                collected.samples += UnsafeBufferPointer(start: ints, count: Int(pcm.frameLength)).map { Float($0) / 32_768 }
            }
        }
    }
    // Linear resampling is plenty for an aligner test.
    let ratio = collected.rate / 16_000
    let source = collected.samples
    guard !source.isEmpty else { return [] }
    return (0 ..< Int(Double(source.count) / ratio)).map { i -> Float in
        let position = Double(i) * ratio
        let index = Int(position)
        let fraction = Float(position - Double(index))
        return source[index] * (1 - fraction) + source[min(index + 1, source.count - 1)] * fraction
    }
}
