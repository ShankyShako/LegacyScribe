import Foundation

/// One read-aloud line. The script is ordered so that stopping at any point still leaves the best
/// training data for the time spent: every English sound first, then sound pairs, then the fine detail
/// (jargon, code talk, numbers). Built by `tools/practice/order_lines.py`.
public struct PracticeLine: Codable, Equatable, Identifiable, Sendable {
	public enum Stage: String, Codable, CaseIterable, Sendable {
		/// Covers every English sound (CMU's 39 phonemes) at least twice.
		case sounds
		/// Adds new sound pairs (diphones), most per word first.
		case pairs
		/// Technical terms, spoken code, numbers, fillers: how this person actually dictates.
		case detail
		/// Lines that add no new sound pair: more samples of known sounds.
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
	/// Phonemes covered once this line and every line before it are recorded (of 39).
	public var soundsCovered: Int
	/// Share of the script's sound pairs covered by then.
	public var pairsCoveredPercent: Int

	public init(id: String, text: String, stage: Stage, soundsCovered: Int, pairsCoveredPercent: Int) {
		self.id = id
		self.text = text
		self.stage = stage
		self.soundsCovered = soundsCovered
		self.pairsCoveredPercent = pairsCoveredPercent
	}
}

public struct PracticeScript: Codable, Equatable, Sendable {
	public static let phonemeCount = 39

	public var version: Int
	public var lines: [PracticeLine]

	public init(version: Int = 1, lines: [PracticeLine]) {
		self.version = version
		self.lines = lines
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

	public init(
		lineID: String,
		text: String,
		audioFileName: String,
		recordedAt: Date,
		duration: TimeInterval,
		recognized: String?,
		engine: String,
		wordErrorRate: Double?
	) {
		self.lineID = lineID
		self.text = text
		self.audioFileName = audioFileName
		self.recordedAt = recordedAt
		self.duration = duration
		self.recognized = recognized
		self.engine = engine
		self.wordErrorRate = wordErrorRate
	}
}

/// Which lines are done. Kept forever, like the audio (calibration data).
public struct PracticeLog: Codable, Equatable, Sendable {
	public var recordings: [String: PracticeRecording] = [:]
	public var skipped: Set<String> = []

	public init(recordings: [String: PracticeRecording] = [:], skipped: Set<String> = []) {
		self.recordings = recordings
		self.skipped = skipped
	}

	/// The first line in script order that is neither recorded nor skipped.
	public func nextLine(in script: PracticeScript) -> PracticeLine? {
		script.lines.first { recordings[$0.id] == nil && !skipped.contains($0.id) }
	}

	/// The furthest line reached in order: what a stopped session has covered.
	public func coverage(in script: PracticeScript) -> PracticeLine? {
		script.lines.last { recordings[$0.id] != nil }
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
