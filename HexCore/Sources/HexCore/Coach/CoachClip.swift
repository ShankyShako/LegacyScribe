import Foundation

/// How one dictation was spoken, for the speech coach (P3.6 D6). Built from a fresh Parakeet (or Apple
/// Speech) transcript of the recording with word timings, plus the recording's loudness for pauses. History's
/// text isn't used: Cohere leaves most fillers out (bench-results, "Fillers in transcripts").
public struct CoachClip: Codable, Equatable, Sendable {
	/// Bumped when the analysis changes; Run analysis redoes older clips whose recording is still there.
	public static let currentVersion = 5

	public var version: Int
	public var dictationID: UUID
	public var date: Date
	public var mode: String?
	public var appName: String?
	/// The engine that transcribed it for the coach.
	public var engine: String
	public var words: Int
	/// From the first word's start to the last word's end.
	public var speakingSeconds: Double
	/// Filler counts keyed by `CoachText.Filler` raw value.
	public var fillers: [String: Int]
	/// Seconds from the first word's start to each filler.
	public var fillerOffsets: [Double]
	/// Self-correction counts keyed by `CoachText.Correction` raw value.
	public var corrections: [String: Int]
	/// Silences after a sentence ends, in seconds.
	public var sentencePauses: [Double]
	/// Silences inside a sentence (between thoughts), in seconds.
	public var thoughtPauses: [Double]
	/// Keyed by `CoachText.Crutch` raw value.
	public var crutches: [String: Int]
	/// Keyed by `CoachText.Hedge` raw value.
	public var hedges: [String: Int]
	/// Spoken words in each sentence.
	public var sentenceLengths: [Int]
	public var runOns: Int
	/// Where things happened in the recording, so the Coach tab can play them back.
	public var moments: [CoachMoment]
	/// Words both engine families got wrong in a way the user then fixed (`CoachMisheard`).
	public var misheard: [CoachMisheard]

	public init(
		dictationID: UUID,
		date: Date,
		mode: String? = nil,
		appName: String? = nil,
		engine: String,
		words: Int,
		speakingSeconds: Double,
		fillers: [String: Int] = [:],
		fillerOffsets: [Double] = [],
		corrections: [String: Int] = [:],
		sentencePauses: [Double] = [],
		thoughtPauses: [Double] = [],
		crutches: [String: Int] = [:],
		hedges: [String: Int] = [:],
		sentenceLengths: [Int] = [],
		runOns: Int = 0,
		moments: [CoachMoment] = [],
		misheard: [CoachMisheard] = []
	) {
		self.version = Self.currentVersion
		self.dictationID = dictationID
		self.date = date
		self.mode = mode
		self.appName = appName
		self.engine = engine
		self.words = words
		self.speakingSeconds = speakingSeconds
		self.fillers = fillers
		self.fillerOffsets = fillerOffsets
		self.corrections = corrections
		self.sentencePauses = sentencePauses
		self.thoughtPauses = thoughtPauses
		self.crutches = crutches
		self.hedges = hedges
		self.sentenceLengths = sentenceLengths
		self.runOns = runOns
		self.moments = moments
		self.misheard = misheard
	}

	/// Clips saved by the first version lack the later fields; they decode as version 1 with those empty.
	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
		dictationID = try c.decode(UUID.self, forKey: .dictationID)
		date = try c.decode(Date.self, forKey: .date)
		mode = try c.decodeIfPresent(String.self, forKey: .mode)
		appName = try c.decodeIfPresent(String.self, forKey: .appName)
		engine = try c.decode(String.self, forKey: .engine)
		words = try c.decode(Int.self, forKey: .words)
		speakingSeconds = try c.decode(Double.self, forKey: .speakingSeconds)
		fillers = try c.decode([String: Int].self, forKey: .fillers)
		fillerOffsets = try c.decode([Double].self, forKey: .fillerOffsets)
		corrections = try c.decode([String: Int].self, forKey: .corrections)
		sentencePauses = try c.decode([Double].self, forKey: .sentencePauses)
		thoughtPauses = try c.decode([Double].self, forKey: .thoughtPauses)
		crutches = try c.decodeIfPresent([String: Int].self, forKey: .crutches) ?? [:]
		hedges = try c.decodeIfPresent([String: Int].self, forKey: .hedges) ?? [:]
		sentenceLengths = try c.decodeIfPresent([Int].self, forKey: .sentenceLengths) ?? []
		runOns = try c.decodeIfPresent(Int.self, forKey: .runOns) ?? 0
		moments = try c.decodeIfPresent([CoachMoment].self, forKey: .moments) ?? []
		misheard = try c.decodeIfPresent([CoachMisheard].self, forKey: .misheard) ?? []
	}

	public var fillerCount: Int { fillers.values.reduce(0, +) }
	public var correctionCount: Int { corrections.values.reduce(0, +) }
}

/// One spot in a recording worth hearing again: a filler, a crutch word, a correction, a run-on's start, or
/// a clean sentence (the good example).
public struct CoachMoment: Codable, Equatable, Sendable {
	public enum Kind: String, Codable, Sendable {
		case filler, crutch, hedge, correction, runOn
		/// A sentence said without a filler, crutch word, hedge or correction, at a steady level.
		case fluent
		/// A silent beat inside a sentence: the good example of version 2 clips. Loudness took quiet speech
		/// for silence, so version 3 plays a clean sentence instead.
		case pause
	}

	public var kind: Kind
	/// The filler, crutch, hedge or correction raw value; empty for sentences, pauses and run-ons.
	public var label: String
	/// Seconds into the recording.
	public var time: Double
	/// How long it lasts, for a moment played whole (a clean sentence); nil for a point in time.
	public var seconds: Double?

	public init(kind: Kind, label: String, time: Double, seconds: Double? = nil) {
		self.kind = kind
		self.label = label
		self.time = time
		self.seconds = seconds
	}
}

/// A word the user said that neither engine family wrote: the dictation engine (Cohere, Apple Speech or
/// WhisperKit) wrote `heard`, the user fixed it to `said` before sending, and the coach's Parakeet pass wrote
/// neither. Two engines that disagree with each other and with the user point at how the word was said;
/// one that agrees with the dictation engine points at an edit or a shared blind spot, so it isn't counted.
public struct CoachMisheard: Codable, Equatable, Sendable {
	public var said: String
	public var heard: String

	public init(said: String, heard: String) {
		self.said = said
		self.heard = heard
	}

	/// Pairs from `pasted` → `sent` that look like spelling fixes (`CorrectionTerms.fixPairs`), kept when
	/// the coach's own transcript (`coachWords`) has neither the pasted nor the sent version.
	public static func find(pasted: String, sent: String, coachWords: [String]) -> [CoachMisheard] {
		let heardByCoach = " " + coachWords.map(key).joined(separator: " ") + " "
		return CorrectionTerms.fixPairs(pasted: pasted, sent: sent, keepGrammar: true).compactMap { pair in
			let said = key(pair.new), heard = key(pair.old)
			guard !said.isEmpty, !heard.isEmpty, said != heard else { return nil }
			guard !heardByCoach.contains(" \(said) "), !heardByCoach.contains(" \(heard) ") else { return nil }
			return CoachMisheard(said: pair.new, heard: pair.old)
		}
	}

	/// Lowercased words without punctuation, apostrophes kept ("can't").
	static func key(_ text: String) -> String {
		text.lowercased().split(separator: " ").map { word in
			word.filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }.replacingOccurrences(of: "’", with: "'")
		}.filter { !$0.isEmpty }.joined(separator: " ")
	}
}

public enum SpeechCoach {
	/// A clean sentence offered as the good example has this many spoken words: long enough to carry a
	/// thought, short enough to hear in one go.
	static let fluentWords = 8 ... 25
	static let fluentSeconds = 2.0 ... 9.0
	/// Clean sentences kept per clip.
	static let fluentPerClip = 2

	/// Analyses one recording from its timed words and samples (mono, any rate). `sentEdit` is the text the user sent after this
	/// dictation, if any; misheard words are looked for only when `dictationEngine` (the engine that wrote
	/// History's text) is another family than `engine`.
	public static func clip(
		for transcript: Transcript,
		engine: String,
		words: [SpokenWord],
		samples: [Float],
		sampleRate: Double,
		sentEdit: SentEdit? = nil,
		dictationEngine: String? = nil
	) -> CoachClip {
		let text = CoachText.analyse(words.map(\.word))
		let first = words.first?.start ?? 0
		let speaking = max(0, (words.last?.end ?? 0) - first)
		let pauses = PauseFinder.pauses(in: samples, sampleRate: sampleRate, words: words)
		let thoughtPauses = pauses.filter { !$0.endsSentence }

		var moments: [CoachMoment] = []
		moments += text.fillers.map { CoachMoment(kind: .filler, label: $0.kind.rawValue, time: words[$0.index].start) }
		moments += text.crutches.map { CoachMoment(kind: .crutch, label: $0.kind.rawValue, time: words[$0.index].start) }
		moments += text.hedges.map { CoachMoment(kind: .hedge, label: $0.kind.rawValue, time: words[$0.index].start) }
		moments += text.corrections.map { CoachMoment(kind: .correction, label: $0.kind.rawValue, time: words[$0.index].start) }
		moments += text.sentences.filter(\.isRunOn).map { CoachMoment(kind: .runOn, label: "", time: words[$0.start].start) }
		moments += fluentSentences(text, words: words, samples: samples, sampleRate: sampleRate, pauses: pauses)

		var misheard: [CoachMisheard] = []
		if let sentEdit, sentEdit.wasEdited, let dictationEngine, family(of: dictationEngine) != family(of: engine) {
			misheard = CoachMisheard.find(pasted: sentEdit.pasted, sent: sentEdit.sent, coachWords: words.map(\.word))
		}

		return CoachClip(
			dictationID: transcript.id,
			date: transcript.timestamp,
			mode: transcript.rewriteMode?.rawValue,
			appName: transcript.sourceAppName,
			engine: engine,
			words: text.words,
			speakingSeconds: speaking,
			fillers: text.fillers.reduce(into: [:]) { $0[$1.kind.rawValue, default: 0] += 1 },
			fillerOffsets: text.fillers.map { max(0, words[$0.index].start - first) },
			corrections: text.corrections.reduce(into: [:]) { $0[$1.kind.rawValue, default: 0] += 1 },
			sentencePauses: pauses.filter(\.endsSentence).map(\.seconds),
			thoughtPauses: thoughtPauses.map(\.seconds),
			crutches: text.crutches.reduce(into: [:]) { $0[$1.kind.rawValue, default: 0] += 1 },
			hedges: text.hedges.reduce(into: [:]) { $0[$1.kind.rawValue, default: 0] += 1 },
			sentenceLengths: text.sentences.map(\.words),
			runOns: text.sentences.filter(\.isRunOn).count,
			moments: moments.sorted { $0.time < $1.time },
			misheard: misheard
		)
	}

	/// Clean sentences to play as good examples, the ones nearest 15 words first: complete (closed by . ? !),
	/// with no filler, crutch word, hedge or correction, no pause over a second, and no stretch much quieter
	/// than the rest of the recording (a speaker turned away from the microphone).
	static func fluentSentences(
		_ text: CoachText.Result, words: [SpokenWord], samples: [Float], sampleRate: Double, pauses: [PauseFinder.Pause]
	) -> [CoachMoment] {
		var flagged = Set(text.fillers.map(\.index))
		flagged.formUnion(text.crutches.map(\.index))
		flagged.formUnion(text.hedges.map(\.index))
		flagged.formUnion(text.corrections.map(\.index))
		let levels = wordLevels(words, samples: samples, sampleRate: sampleRate)
		let typical = levels.map { median($0) }

		return text.sentences.compactMap { sentence -> (CoachMoment, Int)? in
			let range = sentence.start ... sentence.end
			guard fluentWords.contains(sentence.words), let last = words[sentence.end].word.last, ".?!".contains(last),
			      !range.contains(where: flagged.contains) else { return nil }
			let start = words[sentence.start].start
			// TDT runs a word's end into the silence after it.
			let end = min(words[sentence.end].end, words[sentence.end].start + 0.8)
			guard fluentSeconds.contains(end - start),
			      !pauses.contains(where: { $0.start > start && $0.start < end && $0.seconds > 1.0 }) else { return nil }
			if let levels, let typical {
				let inside = levels[range].sorted()
				// Its quietest fifth of words and its middle word against the recording's middle word.
				guard inside[inside.count / 5] >= typical * 0.3, inside[inside.count / 2] >= typical * 0.6 else { return nil }
			}
			return (CoachMoment(kind: .fluent, label: "", time: start, seconds: end - start), abs(sentence.words - 15))
		}
		.sorted { $0.1 < $1.1 }.prefix(fluentPerClip).map(\.0)
	}

	/// Each word's loudness (RMS over its first 0.4 s, since TDT runs ends long), or nil without samples.
	static func wordLevels(_ words: [SpokenWord], samples: [Float], sampleRate: Double) -> [Float]? {
		guard !samples.isEmpty, !words.isEmpty else { return nil }
		return words.map { word in
			let from = min(samples.count, max(0, Int(word.start * sampleRate)))
			let to = min(samples.count, max(from, Int(min(word.end, word.start + 0.4) * sampleRate)))
			guard to > from else { return 0 }
			var sum: Float = 0
			for sample in samples[from ..< to] { sum += sample * sample }
			return (sum / Float(to - from)).squareRoot()
		}
	}

	static func median(_ values: [Float]) -> Float {
		values.sorted()[values.count / 2]
	}

	/// Engines whose mistakes go together. The Parakeet variants share their errors (`PracticeGrade`), so
	/// they are one family.
	static func family(of engine: String) -> String {
		let lower = engine.lowercased()
		if lower.contains("parakeet") { return "parakeet" }
		if lower.contains("cohere") { return "cohere" }
		if lower.contains("apple") { return "apple" }
		return "whisper"
	}
}
