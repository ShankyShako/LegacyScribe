import FluidAudio
import Foundation

/// `lsbench voice --enrol <folder> --same <folder> --other <folder>... [--embedder campplus|wespeaker]
/// [--enrol-from-same N] [--per-file N] [--per-speaker N]`, or `--timeline <file>` in place of `--same`/`--other`:
/// can FluidAudio's speaker embeddings tell the user's voice from others' (P3.6 D6, the voiceprint
/// check before Notes counting)? The voiceprint is the mean embedding of every clip in `--enrol` (the
/// read-aloud recordings). Stretches of 1, 2 and 5 s of contiguous speech (Silero VAD, the notes settings)
/// are cut from `--same` (held-out recordings of the user) and each `--other` folder (searched recursively;
/// a file's speaker is its name up to the first "-", as in LibriSpeech and `say` clips), and each is
/// scored by cosine similarity against the voiceprint. Whole VAD turns are scored too (their first 10 s),
/// reported by turn length. `--enrol-from-same N` enrols from N of the `--same` recordings (spread over
/// them, whole files) instead of `--enrol`, and leaves them out of the test. `--embedder wespeaker` uses
/// the diarizer's WeSpeaker v2 (256-d, 10 s window; longer audio is averaged over 10 s pieces) instead of
/// CAM++ (whose features are capped at 60 s, so longer enrolment audio is averaged over 50 s pieces). Prints the score spread per stretch length, the equal error rate, the error at a few operating
/// points, the most user-like other speakers and the least user-like stretches of the user. `--timeline`
/// scores 1 s and 2 s windows every 0.5 s through each given file instead, for a recording that mixes the
/// user with someone else (a video playing in the room).
func runVoiceBench(_ arguments: [String]) async throws {
    var enrolPaths: [String] = [], samePaths: [String] = [], otherPaths: [String] = [], timelinePaths: [String] = []
    var diarizePaths: [String] = [], asrSpec = "parakeet:v3"
    var perFile = 4, perSpeaker = 10, enrolFromSame = 0
    var embedderName = "campplus"
    var index = 0
    while index < arguments.count {
        let value = index + 1 < arguments.count ? arguments[index + 1] : ""
        switch arguments[index] {
        case "--enrol": enrolPaths.append(value)
        case "--same": samePaths.append(value)
        case "--other": otherPaths.append(value)
        case "--timeline": timelinePaths.append(value)
        case "--diarize": diarizePaths.append(value)
        case "--asr": asrSpec = value
        case "--embedder": embedderName = value
        case "--enrol-from-same": enrolFromSame = Int(value) ?? 0
        case "--per-file": perFile = Int(value) ?? perFile
        case "--per-speaker": perSpeaker = Int(value) ?? perSpeaker
        default:
            print("unknown argument \(arguments[index])")
            return
        }
        index += 2
    }
    guard !enrolPaths.isEmpty || enrolFromSame > 0, !timelinePaths.isEmpty || !diarizePaths.isEmpty || (!samePaths.isEmpty && !otherPaths.isEmpty),
          ["campplus", "wespeaker"].contains(embedderName) else {
        print("usage: lsbench voice --enrol <folder> --same <folder> --other <folder>... [--embedder campplus|wespeaker] [--enrol-from-same N] [--per-file N] [--per-speaker N] | --timeline <file>... | --diarize <file>... [--asr parakeet:v3]")
        return
    }

    let modelsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LegacyScribe/Models/fluidaudio")
    let embed: ([Float]) async throws -> [Float]
    var wespeakerDiarizer: DiarizerManager?
    if embedderName == "wespeaker" {
        let diarizer = DiarizerManager()
        diarizer.initialize(models: try await DiarizerModels.download(to: modelsRoot.appendingPathComponent("speaker-diarization")))
        wespeakerDiarizer = diarizer
        let window = 160_000
        embed = { audio in
            // The model sees 10 s; longer audio is the normalized mean of its 10 s pieces (a tail under 1 s is dropped).
            let pieces = stride(from: 0, to: audio.count, by: window)
                .map { audio[$0 ..< min(audio.count, $0 + window)] }
                .filter { $0.count >= 16_000 || audio.count < 16_000 }
            return normalizedMean(try pieces.map { try diarizer.extractSpeakerEmbedding(from: Array($0)) })
        }
    } else {
        let campDirectory = modelsRoot.appendingPathComponent(Repo.campPlus.folderName)
        if !CampPlusModels.modelsExist(at: campDirectory) { try await ModelHub.download(.campPlus, to: modelsRoot) }
        let embedder = CampPlusEmbedder(models: try CampPlusModels.load(from: campDirectory))
        // CAM++ features stop at 60 s (6,000 frames); longer audio is the normalized mean of its 50 s pieces.
        let window = 800_000
        embed = { audio in
            guard audio.count > 940_000 else { return try await embedder.embed(audio: audio) }
            var pieces: [[Float]] = []
            for start in stride(from: 0, to: audio.count, by: window) where audio.count - start >= 16_000 {
                pieces.append(try await embedder.embed(audio: Array(audio[start ..< min(audio.count, start + window)])))
            }
            return normalizedMean(pieces)
        }
    }
    print("Embedder: \(embedderName)")
    let vadModels = try await ModelHub.loadModels(.vad, modelNames: Array(ModelNames.VAD.requiredModels), directory: modelsRoot)
    guard let vadModel = vadModels[ModelNames.VAD.sileroVadFile] else { throw VadError.modelLoadingFailed }
    let vad = VadManager(vadModel: vadModel)
    let segmentation = VadSegmentationConfig(minSpeechDuration: 0.3, speechPadding: 0.3)
    let converter = AudioConverter()
    let rate = 16_000

    // Enrolment: one embedding per clip, averaged. Taken from the user's own recordings, they're held out of the test.
    var sameFiles = audioFiles(samePaths, recursive: false)
    let enrolFiles: [URL]
    if enrolFromSame > 0 {
        let step = max(1, sameFiles.count / enrolFromSame)
        let picked = Set(stride(from: 0, to: sameFiles.count, by: step).prefix(enrolFromSame))
        enrolFiles = picked.sorted().map { sameFiles[$0] }
        sameFiles = sameFiles.indices.filter { !picked.contains($0) }.map { sameFiles[$0] }
    } else {
        enrolFiles = audioFiles(enrolPaths, recursive: false)
    }
    var enrolEmbeddings: [[Float]] = []
    for url in enrolFiles { enrolEmbeddings.append(try await embed(try converter.resampleAudioFile(url))) }
    let voiceprint = normalizedMean(enrolEmbeddings)
    let selfScores = enrolEmbeddings.map { CampPlusEmbedder.cosine($0, voiceprint) }.sorted()
    print(String(format: "Voiceprint from %d clips; their own scores against it: min %.2f, median %.2f", enrolFiles.count,
                 selfScores.first ?? 0, selfScores.isEmpty ? 0 : selfScores[selfScores.count / 2]))

    if !diarizePaths.isEmpty {
        // The diarizer's segment embeddings are WeSpeaker's, so they score against the voiceprint directly.
        guard let diarizer = wespeakerDiarizer else {
            print("--diarize needs --embedder wespeaker")
            return
        }
        try await runDiarization(audioFiles(diarizePaths, recursive: false), diarizer: diarizer, voiceprint: voiceprint,
                                 asr: try makeEngine(asrSpec, cohereChunkSeconds: nil), converter: converter)
        return
    }

    if !timelinePaths.isEmpty {
        for url in audioFiles(timelinePaths, recursive: false) {
            let samples = try converter.resampleAudioFile(url)
            print("\n\(url.lastPathComponent), \(String(format: "%.1f", Double(samples.count) / Double(rate))) s")
            for length in [1.0, 2.0] {
                let size = Int(length * Double(rate))
                var line: [String] = []
                for start in stride(from: 0, through: samples.count - size, by: rate / 2) {
                    let score = CampPlusEmbedder.cosine(try await embed(Array(samples[start ..< start + size])), voiceprint)
                    line.append(String(format: "%.1f:%.2f", Double(start) / Double(rate), score))
                }
                print(String(format: "  %.0f s windows (start:score) ", length) + line.joined(separator: " "))
            }
        }
        return
    }

    struct Score {
        var score: Float
        var file: String
        var speaker: String
        var start: Double
    }
    let lengths: [Double] = [1, 2, 5]
    // Whole turns by length: label, shortest and longest in seconds.
    let turnBuckets: [(label: String, shortest: Double, longest: Double)] = [
        ("turn 1-2 s", 1, 2), ("turn 2-5 s", 2, 5), ("turn 5+ s", 5, .infinity),
    ]
    let labels = lengths.map { String(format: "%.0f s", $0) } + turnBuckets.map(\.label)
    var embedSeconds = 0.0, embedCount = 0

    func scored(_ audio: ArraySlice<Float>, file: String, speaker: String, start: Int) async throws -> Score {
        let began = Date()
        let embedding = try await embed(Array(audio))
        embedSeconds += Date().timeIntervalSince(began)
        embedCount += 1
        return Score(score: CampPlusEmbedder.cosine(embedding, voiceprint), file: file, speaker: speaker,
                     start: Double(start) / Double(rate))
    }

    // Up to `perFile` stretches of each length from the file's speech, spread over it, and up to
    // `perFile` whole turns per bucket (their first 10 s).
    func scores(_ url: URL, speaker: String) async throws -> [String: [Score]] {
        let samples = try converter.resampleAudioFile(url)
        let segments = try await vad.segmentSpeech(samples, config: segmentation)
        let ranges = segments.map { ($0.startSample(sampleRate: rate), min(samples.count, $0.endSample(sampleRate: rate))) }
        var result: [String: [Score]] = [:]
        for length in lengths {
            let size = Int(length * Double(rate))
            var starts: [Int] = []
            for (begin, end) in ranges {
                var from = begin
                while from + size <= end {
                    starts.append(from)
                    from += size
                }
            }
            let step = max(1, starts.count / perFile)
            for start in stride(from: 0, to: starts.count, by: step).prefix(perFile).map({ starts[$0] }) {
                result[String(format: "%.0f s", length), default: []].append(
                    try await scored(samples[start ..< start + size], file: url.lastPathComponent, speaker: speaker, start: start))
            }
        }
        for bucket in turnBuckets {
            let turns = ranges.filter {
                let seconds = Double($0.1 - $0.0) / Double(rate)
                return seconds >= bucket.shortest && seconds < bucket.longest
            }
            let step = max(1, turns.count / perFile)
            for (from, to) in stride(from: 0, to: turns.count, by: step).prefix(perFile).map({ turns[$0] }) {
                result[bucket.label, default: []].append(
                    try await scored(samples[from ..< min(to, from + 10 * rate)], file: url.lastPathComponent, speaker: speaker, start: from))
            }
        }
        return result
    }

    var same: [String: [Score]] = [:]
    for url in sameFiles {
        for (label, found) in try await scores(url, speaker: "user") { same[label, default: []] += found }
    }
    // Each --other folder is a group (LibriSpeech, say voices…), reported apart and together.
    var others: [(group: String, scores: [String: [Score]])] = []
    for path in otherPaths {
        var perSpeakerCount: [String: Int] = [:]
        var group: [String: [Score]] = [:]
        for url in audioFiles([path], recursive: true) {
            let speaker = String(url.deletingPathExtension().lastPathComponent.prefix { $0 != "-" })
            guard perSpeakerCount[speaker, default: 0] < perSpeaker else { continue }
            perSpeakerCount[speaker, default: 0] += 1
            for (label, found) in try await scores(url, speaker: speaker) { group[label, default: []] += found }
        }
        others.append(((path as NSString).lastPathComponent, group))
        print("\((path as NSString).lastPathComponent): \(perSpeakerCount.count) speakers")
    }
    print(String(format: "%d stretches embedded, %.1f ms each", embedCount, embedSeconds / Double(max(embedCount, 1)) * 1000))

    func percentiles(_ values: [Float]) -> String {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return "–" }
        return [0.05, 0.25, 0.5, 0.75, 0.95].map { String(format: "%.2f", sorted[min(sorted.count - 1, Int($0 * Double(sorted.count)))]) }
            .joined(separator: " / ")
    }
    /// Equal error rate and its threshold, and the false-accept rate when 95% and 90% of the user's
    /// stretches are accepted.
    func errors(same: [Float], other: [Float]) -> String {
        let sameSorted = same.sorted(), otherSorted = other.sorted()
        guard !sameSorted.isEmpty, !otherSorted.isEmpty else { return "–" }
        func far(_ threshold: Float) -> Double { Double(otherSorted.filter { $0 >= threshold }.count) / Double(otherSorted.count) }
        func frr(_ threshold: Float) -> Double { Double(sameSorted.filter { $0 < threshold }.count) / Double(sameSorted.count) }
        let best = (sameSorted + otherSorted).min { abs(far($0) - frr($0)) < abs(far($1) - frr($1)) }!
        let at95 = sameSorted[Int(0.05 * Double(sameSorted.count))], at90 = sameSorted[Int(0.10 * Double(sameSorted.count))]
        return String(format: "EER %.1f%% at %.2f; accepting 95%% of the user (≥ %.2f) lets in %.1f%% of others, 90%% (≥ %.2f) %.1f%%",
                      (far(best) + frr(best)) / 2 * 100, best, at95, far(at95) * 100, at90, far(at90) * 100)
    }

    for label in labels {
        let user = (same[label] ?? []).map(\.score)
        print("\n\(label): user \(user.count), percentiles 5/25/50/75/95: \(percentiles(user))")
        var all: [Score] = []
        for (group, scores) in others {
            let found = scores[label] ?? []
            all += found
            print(String(format: "  %@ %d: %@  ·  %@", group, found.count, percentiles(found.map(\.score)), errors(same: user, other: found.map(\.score))))
        }
        if others.count > 1 { print("  all others: " + errors(same: user, other: all.map(\.score))) }
        // The other speakers closest to the user, by their median score.
        let bySpeaker = Dictionary(grouping: all, by: \.speaker).mapValues { $0.map(\.score).sorted() }
        let closest = bySpeaker.sorted { $0.value[$0.value.count / 2] > $1.value[$1.value.count / 2] }.prefix(5)
        print("  closest others (median, max): " + closest.map { String(format: "%@ %.2f %.2f", $0.key, $0.value[$0.value.count / 2], $0.value.last!) }.joined(separator: ", "))
        let lowest = (same[label] ?? []).sorted { $0.score < $1.score }.prefix(5)
        print("  user's lowest: " + lowest.map { String(format: "%@@%.1f %.2f", $0.file, $0.start, $0.score) }.joined(separator: ", "))
    }
}

/// `--diarize`: who spoke when in a recording of several people, and which speaker is the user. FluidAudio's
/// diarizer (pyannote segmentation + WeSpeaker, default clustering) splits the recording; each speaker's
/// mean embedding and each turn's are scored against the voiceprint (0.4 split the user from a video in
/// the same room); each turn (consecutive segments of one speaker, gaps under 1 s, at most 30 s) is
/// transcribed with `asr`. Prints a per-speaker summary, then the labelled transcript.
private func runDiarization(_ files: [URL], diarizer: DiarizerManager, voiceprint: [Float], asr: BenchEngine,
                            converter: AudioConverter) async throws {
    let rate = 16_000
    var asrLoaded = false
    func clock(_ seconds: Float) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
    for url in files {
        let samples = try converter.resampleAudioFile(url)
        let began = Date()
        let result = try diarizer.performCompleteDiarization(samples, sampleRate: rate)
        // Segment embeddings aren't unit length; normalize them so every mean weighs segments alike.
        let segments = result.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }.map {
            TimedSpeakerSegment(speakerId: $0.speakerId, embedding: normalizedMean([$0.embedding]),
                                startTimeSeconds: $0.startTimeSeconds, endTimeSeconds: $0.endTimeSeconds, qualityScore: $0.qualityScore)
        }
        print(String(format: "\n%@, %.1f s: %d segments, %d speakers, diarized in %.1f s", url.lastPathComponent,
                     Double(samples.count) / Double(rate), segments.count, Set(segments.map(\.speakerId)).count,
                     Date().timeIntervalSince(began)))

        let bySpeaker = Dictionary(grouping: segments, by: \.speakerId)
        var speakerScore: [String: Float] = [:]
        for (speaker, found) in bySpeaker {
            speakerScore[speaker] = CampPlusEmbedder.cosine(normalizedMean(found.map(\.embedding)), voiceprint)
        }
        print("speaker   time    segments  voiceprint (speaker mean; segments min/median/max)")
        for (speaker, found) in bySpeaker.sorted(by: { $0.value.map(\.durationSeconds).reduce(0, +) > $1.value.map(\.durationSeconds).reduce(0, +) }) {
            let scores = found.map { CampPlusEmbedder.cosine($0.embedding, voiceprint) }.sorted()
            print(String(format: "S%-7@ %6.1f s %5d     %.2f  (%.2f / %.2f / %.2f)", speaker,
                         found.map(\.durationSeconds).reduce(0, +), found.count, speakerScore[speaker] ?? 0,
                         scores.first ?? 0, scores[scores.count / 2], scores.last ?? 0))
        }

        // Turns: consecutive segments of one speaker.
        var turns: [[TimedSpeakerSegment]] = []
        for segment in segments {
            if let last = turns.last?.last, last.speakerId == segment.speakerId,
               segment.startTimeSeconds - last.endTimeSeconds < 1, segment.endTimeSeconds - turns.last![0].startTimeSeconds <= 30 {
                turns[turns.count - 1].append(segment)
            } else {
                turns.append([segment])
            }
        }
        if !asrLoaded {
            try await asr.load(warmup: Array(samples.prefix(rate)))
            asrLoaded = true
        }
        print("\nturns (start-end speaker turn-score: text)")
        for turn in turns {
            let from = Int(turn[0].startTimeSeconds * Float(rate)), to = min(samples.count, Int(turn.last!.endTimeSeconds * Float(rate)))
            guard to - from >= rate / 2 else { continue }
            let text = try await asr.transcribe(Array(samples[from ..< to]))
            let score = CampPlusEmbedder.cosine(normalizedMean(turn.map(\.embedding)), voiceprint)
            print(String(format: "%@-%@ S%@ %.2f: %@", clock(turn[0].startTimeSeconds), clock(turn.last!.endTimeSeconds),
                         turn[0].speakerId, score, text))
        }
    }
    asr.unload()
}

/// The L2-normalized mean of the given embeddings.
private func normalizedMean(_ embeddings: [[Float]]) -> [Float] {
    guard let first = embeddings.first else { return [] }
    var sum = [Float](repeating: 0, count: first.count)
    for embedding in embeddings { for i in sum.indices { sum[i] += embedding[i] } }
    let norm = max(sum.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-9)
    return sum.map { $0 / norm }
}

/// Audio files in the given files and folders, sorted.
private func audioFiles(_ paths: [String], recursive: Bool) -> [URL] {
    let extensions: Set<String> = ["wav", "flac", "m4a", "caf", "mp3"]
    return paths.flatMap { path -> [URL] in
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [url] }
        if recursive {
            let found = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            return found.filter { extensions.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
            .map { url.appendingPathComponent($0) }
    }
}
