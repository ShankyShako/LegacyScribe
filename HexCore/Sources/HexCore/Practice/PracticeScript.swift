import Foundation

/// One read-aloud line, with the sounds it contains so a practice set can be picked to fill whatever
/// the recordings so far are missing. Built by `tools/practice/order_lines.py`.
public struct PracticeLine: Codable, Equatable, Hashable, Identifiable, Sendable {
	/// What kind of line it is, and the slot it fills in a practice set.
	public enum Stage: String, Codable, CaseIterable, Sendable {
		/// Lines rich in sounds the recordings have least of (CMU's 39 phonemes).
		case sounds
		/// Lines with sound pairs (diphones) not yet recorded.
		case pairs
		/// Technical terms, spoken code, numbers, fillers: how this person actually dictates.
		case detail
		/// Ordinary lines: more samples of known sounds.
		case extra

		public var title: String {
			switch self {
			case .sounds: "Every sound"
			case .pairs: "Sound combinations"
			case .detail: "Fine detail"
			case .extra: "More practice"
			}
		}
	}

	public var id: String
	public var text: String
	public var stage: Stage
	/// Phoneme → how often it occurs in the line.
	public var sounds: [String: Int]
	/// Adjacent phoneme pairs, as "AA-B".
	public var pairs: [String]
	/// Words the pronouncing dictionary doesn't know (jargon, product names).
	public var terms: [String]

	public init(
		id: String,
		text: String,
		stage: Stage,
		sounds: [String: Int] = [:],
		pairs: [String] = [],
		terms: [String] = []
	) {
		self.id = id
		self.text = text
		self.stage = stage
		self.sounds = sounds
		self.pairs = pairs
		self.terms = terms
	}

	public var wordCount: Int {
		max(1, text.split(whereSeparator: \.isWhitespace).count)
	}
}

public struct PracticeScript: Codable, Equatable, Sendable {
	public static let phonemeCount = 39

	public var version: Int
	public var lines: [PracticeLine]

	public init(version: Int = 2, lines: [PracticeLine]) {
		self.version = version
		self.lines = lines
	}

	public func line(id: String) -> PracticeLine? {
		lines.first { $0.id == id }
	}

	/// Every sound pair in the script: the denominator for "how much is covered".
	public var allPairs: Set<String> {
		Set(lines.flatMap(\.pairs))
	}
}

/// A recorded line. The audio sits next to a `.txt` with the line's text, the format `lsbench` reads as
/// a fixture, so the same recordings benchmark every engine on this voice.
public struct PracticeRecording: Codable, Equatable, Sendable {
	public var lineID: String
	public var text: String
	public var audioFileName: String
	public var recordedAt: Date
	public var duration: TimeInterval
	/// What the engine heard, for the per-line score; nil if transcription failed.
	public var recognized: String?
	public var engine: String
	public var wordErrorRate: Double?
	/// Set by the user once a model has been trained on this recording.
	public var trainedAt: Date?
	/// When the audio was deleted to free space. The line stays recorded, so it isn't asked again.
	public var audioClearedAt: Date?

	public init(
		lineID: String,
		text: String,
		audioFileName: String,
		recordedAt: Date,
		duration: TimeInterval,
		recognized: String?,
		engine: String,
		wordErrorRate: Double?,
		trainedAt: Date? = nil,
		audioClearedAt: Date? = nil
	) {
		self.lineID = lineID
		self.text = text
		self.audioFileName = audioFileName
		self.recordedAt = recordedAt
		self.duration = duration
		self.recognized = recognized
		self.engine = engine
		self.wordErrorRate = wordErrorRate
		self.trainedAt = trainedAt
		self.audioClearedAt = audioClearedAt
	}

	public var hasAudio: Bool { audioClearedAt == nil }
	public var isTrained: Bool { trainedAt != nil }
}

/// Which lines are recorded, skipped or already shown. Kept forever, like the audio (calibration data).
public struct PracticeLog: Codable, Equatable, Sendable {
	public var recordings: [String: PracticeRecording] = [:]
	public var skipped: Set<String> = []
	/// Lines shown in a session, recorded or not. New sets prefer lines not in here.
	public var seen: Set<String> = []

	public init(recordings: [String: PracticeRecording] = [:], skipped: Set<String> = [], seen: Set<String> = []) {
		self.recordings = recordings
		self.skipped = skipped
		self.seen = seen
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		recordings = try container.decodeIfPresent([String: PracticeRecording].self, forKey: .recordings) ?? [:]
		skipped = try container.decodeIfPresent(Set<String>.self, forKey: .skipped) ?? []
		seen = try container.decodeIfPresent(Set<String>.self, forKey: .seen) ?? []
	}

	public func hasSeen(_ id: String) -> Bool {
		seen.contains(id) || skipped.contains(id) || recordings[id] != nil
	}

	/// Sounds, pairs and terms in every recorded line.
	public func coverage(in script: PracticeScript) -> PracticeCoverage {
		PracticeCoverage(script.lines.filter { recordings[$0.id] != nil })
	}

	/// Recorded lines that still have audio and aren't marked trained.
	public var untrained: [PracticeRecording] {
		recordings.values.filter { $0.hasAudio && !$0.isTrained }
	}

	/// Trained lines whose audio is still on disk.
	public var trainedWithAudio: [PracticeRecording] {
		recordings.values.filter { $0.hasAudio && $0.isTrained }
	}

	/// Drops recordings whose audio has gone missing (deleted in Finder, a crash mid-save), so their
	/// lines can be recorded again. Lines cleared on purpose stay. Returns how many were dropped.
	@discardableResult
	public mutating func dropMissingAudio(present audioFiles: Set<String>) -> Int {
		let missing = recordings.filter { $0.value.hasAudio && !audioFiles.contains($0.value.audioFileName) }
		for id in missing.keys {
			recordings[id] = nil
		}
		return missing.count
	}

	public var recordedSeconds: TimeInterval {
		recordings.values.reduce(0) { $0 + $1.duration }
	}

	/// Word error rate over every recorded line that was transcribed.
	public var overallWordErrorRate: Double? {
		var errors = 0.0, words = 0
		for recording in recordings.values {
			guard let rate = recording.wordErrorRate else { continue }
			let count = WordErrorRate.normalize(recording.text).count
			errors += rate * Double(count)
			words += count
		}
		return words == 0 ? nil : errors / Double(words)
	}
}

/// Word error rate over normalized words (lowercased, punctuation dropped), so formatting choices don't
/// count as errors. Same rules as `tools/lsbench/Sources/lsbench/WER.swift`.
public enum WordErrorRate {
	public static func normalize(_ text: String) -> [String] {
		let lowered = text.lowercased()
			.replacingOccurrences(of: "’", with: "'")
			.replacingOccurrences(of: "-", with: " ")
		let kept = lowered.unicodeScalars.map { scalar -> Character in
			CharacterSet.alphanumerics.contains(scalar) || scalar == "'" ? Character(scalar) : " "
		}
		return String(kept).split(separator: " ")
			.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
			.filter { !$0.isEmpty }
	}

	public static func rate(reference: String, hypothesis: String) -> Double {
		let ref = normalize(reference), hyp = normalize(hypothesis)
		guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
		guard !hyp.isEmpty else { return 1 }
		var previous = Array(0 ... hyp.count)
		for r in 1 ... ref.count {
			var current = [r]
			for h in 1 ... hyp.count {
				let substitution = previous[h - 1] + (ref[r - 1] == hyp[h - 1] ? 0 : 1)
				current.append(min(substitution, previous[h] + 1, current[h - 1] + 1))
			}
			previous = current
		}
		return Double(previous[hyp.count]) / Double(ref.count)
	}
}
