import Foundation

/// How well an engine heard a read-aloud line, setting aside what wasn't the engine's fault.
///
/// A plain word error rate against the script blames the engine for everything. Three kinds of difference
/// aren't hearing errors:
/// - formatting: "2.4.1" for "two point four point one", "Swift UI" for "SwiftUI";
/// - new words: terms the line marks as jargon (`PracticeLine.terms`) that no engine can spell unaided,
///   such as "OmniRoot" for "OmniRoute". Vocabulary and the rewrite fix those;
/// - what the reader actually said: when engines from two unrelated families (Cohere and Parakeet) hear the
///   same different word at the same place, the audio most likely carries it ("equitable" read for
///   "equatable", "gather" for "gathered"). Such a recording also shouldn't be trained on with the script
///   as its label.
///
/// What's left counts against the engine. `heard` is the share of script words it got, and a line passes
/// at 95% (`passMark`). Checked on 68 recorded lines (2026-10-10): Cohere 4-bit heard 100% of 594 words once
/// 9 read-differently words and 4 new-word spellings were set aside; literally, 59 of 68 lines passed.
public struct PracticeGrade: Equatable, Sendable {
	public static let passMark = 0.95

	public enum Kind: String, Codable, Equatable, Sendable {
		/// The engine got it wrong.
		case misheard
		/// Both engine families heard the same other word: most likely what was said.
		case saidDifferently
		/// A jargon term spelled another way.
		case newWord
	}

	/// One difference from the script. `expected` is nil for an extra word, `heard` nil for a missing one.
	public struct Difference: Equatable, Sendable {
		public var expected: String?
		public var heard: String?
		public var kind: Kind
	}

	/// Words in the script, after normalizing.
	public var words: Int
	public var differences: [Difference]

	public var misheardCount: Int { differences.filter { $0.kind == .misheard }.count }

	/// Share of script words the engine heard right, not counting what was said differently or new words.
	public var heard: Double {
		words == 0 ? 1 : max(0, 1 - Double(misheardCount) / Double(words))
	}

	/// Share of script words matched exactly, counting every difference.
	public var literal: Double {
		words == 0 ? 1 : max(0, 1 - Double(differences.count) / Double(words))
	}

	public var passes: Bool { heard >= Self.passMark }

	/// Grades `heard` (the engine being graded) against `script`. `otherFamily` is another engine family's
	/// transcript of the same audio, if there is one; without it nothing can be put down to the reader.
	public static func grade(script: String, heard: String, otherFamily: String? = nil, terms: [String] = []) -> PracticeGrade {
		let reference = normalize(script)
		let differences = PracticeAlignment.differences(reference: reference, hypothesis: normalize(heard))
		let confirmed = otherFamily.map { Set(PracticeAlignment.differences(reference: reference, hypothesis: normalize($0))) } ?? []
		let newWords = Set(terms.flatMap(normalize))

		return PracticeGrade(
			words: reference.count,
			differences: differences.map { difference in
				let kind: Kind
				if let expected = difference.expected, newWords.contains(expected) {
					kind = .newWord
				} else if confirmed.contains(difference) {
					kind = .saidDifferently
				} else {
					kind = .misheard
				}
				return Difference(expected: difference.expected, heard: difference.heard, kind: kind)
			}
		)
	}

	// MARK: - Normalizing

	/// Lowercased words without punctuation or fillers, digits spelled out, so "2.4.1" and "two point four
	/// point one" compare equal.
	public static func normalize(_ text: String) -> [String] {
		var text = text.lowercased()
			.replacingOccurrences(of: "’", with: "'")
			.replacingOccurrences(of: "-", with: " ")
			.replacingOccurrences(of: "%", with: " percent")
		// Matches overlap in "2.4.1", so repeat until nothing changes.
		for (pattern, template) in [(#"(\d)\.(\d)"#, "$1 point $2"), (#"(\d):(\d)"#, "$1 $2")] {
			var previous = ""
			while previous != text {
				previous = text
				text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
			}
		}
		var spelled = ""
		var digits = ""
		func flush() {
			if let number = Int(digits) { spelled += " \(numberWords(number)) " }
			digits = ""
		}
		for character in text {
			if character.isASCII, character.isNumber {
				digits.append(character)
			} else {
				flush()
				spelled.append(character.isLetter || character == "'" ? character : " ")
			}
		}
		flush()
		return spelled.split(separator: " ")
			.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
			.filter { !$0.isEmpty && !fillers.contains($0) }
	}

	static let fillers: Set<String> = ["uh", "um", "er", "hmm", "hm"]

	static func numberWords(_ number: Int) -> String {
		let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
		            "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
		let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
		switch number {
		case ..<0: return String(number)
		case ..<20: return ones[number]
		case ..<100: return tens[number / 10] + (number % 10 == 0 ? "" : " " + ones[number % 10])
		case ..<1000: return ones[number / 100] + " hundred" + (number % 100 == 0 ? "" : " " + numberWords(number % 100))
		// Years and ports are read in pairs: 2026 is "twenty twenty six", 20128 stays digits-as-said.
		case ..<10000 where number % 1000 >= 10: return numberWords(number / 100) + " " + numberWords(number % 100)
		default: return String(number).map { ones[Int(String($0))!] }.joined(separator: " ")
		}
	}
}

/// Word alignment of a transcript against a script.
enum PracticeAlignment {
	/// One difference, anchored at the script position it falls on so two transcripts can be compared.
	struct Raw: Hashable {
		var position: Int
		var expected: String?
		var heard: String?
	}

	static func differences(reference: [String], hypothesis: [String]) -> [Raw] {
		let n = reference.count, m = hypothesis.count
		var cost = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
		for i in 0...n { cost[i][0] = i }
		for j in 0...m { cost[0][j] = j }
		if n > 0, m > 0 {
			for i in 1...n {
				for j in 1...m {
					cost[i][j] = min(
						cost[i - 1][j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1),
						cost[i - 1][j] + 1,
						cost[i][j - 1] + 1
					)
				}
			}
		}
		var steps: [Raw] = []
		var i = n, j = m
		while i > 0 || j > 0 {
			if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1) {
				steps.append(Raw(position: i - 1, expected: reference[i - 1], heard: hypothesis[j - 1]))
				i -= 1; j -= 1
			} else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
				steps.append(Raw(position: i - 1, expected: reference[i - 1], heard: nil))
				i -= 1
			} else {
				steps.append(Raw(position: i, expected: nil, heard: hypothesis[j - 1]))
				j -= 1
			}
		}
		return joinCompounds(steps.reversed()).filter { $0.expected != $0.heard }
	}

	/// "swift ui" for "swiftui" or "pull request" for "pullrequest": runs of two or three steps that spell
	/// the same letters are one match.
	static func joinCompounds(_ steps: [Raw]) -> [Raw] {
		var result: [Raw] = []
		var index = 0
		outer: while index < steps.count {
			for span in [2, 3] where index + span <= steps.count {
				let run = steps[index ..< index + span]
				let expected = run.compactMap(\.expected).joined()
				let heard = run.compactMap(\.heard).joined()
				if !expected.isEmpty, expected == heard, run.contains(where: { $0.expected != $0.heard }) {
					result.append(Raw(position: run.first!.position, expected: expected, heard: heard))
					index += span
					continue outer
				}
			}
			result.append(steps[index])
			index += 1
		}
		return result
	}
}

/// Grades over every recorded line: what the Practice tab shows after "Check my recordings".
public struct PracticeGradeSummary: Equatable, Sendable {
	public struct Line: Equatable, Identifiable, Sendable {
		public var id: String
		public var text: String
		public var grade: PracticeGrade
	}

	public var lines: [Line]

	public var words: Int { lines.reduce(0) { $0 + $1.grade.words } }
	public var misheard: Int { lines.reduce(0) { $0 + $1.grade.misheardCount } }
	public var heard: Double { words == 0 ? 1 : max(0, 1 - Double(misheard) / Double(words)) }
	public var passing: Int { lines.filter(\.grade.passes).count }
	public var belowMark: [Line] { lines.filter { !$0.grade.passes }.sorted { $0.grade.heard < $1.grade.heard } }

	/// Words the reader most likely said differently, most frequent first, e.g. ("equatable", "equitable").
	public var saidDifferently: [PracticeGrade.Difference] { differences(.saidDifferently) }
	public var newWords: [PracticeGrade.Difference] { differences(.newWord) }

	private func differences(_ kind: PracticeGrade.Kind) -> [PracticeGrade.Difference] {
		lines.flatMap { $0.grade.differences.filter { $0.kind == kind } }
	}
}

extension PracticeLog {
	/// Grades every transcribed recording; `terms` gives a line's jargon (`PracticeLine.terms`) by ID.
	public func gradeSummary(terms: (String) -> [String] = { _ in [] }) -> PracticeGradeSummary {
		PracticeGradeSummary(lines: recordings.values
			.compactMap { recording in
				guard let heard = recording.recognized else { return nil }
				return PracticeGradeSummary.Line(
					id: recording.lineID,
					text: recording.text,
					grade: .grade(script: recording.text, heard: heard, otherFamily: recording.secondOpinion, terms: terms(recording.lineID))
				)
			}
			.sorted { $0.id < $1.id })
	}
}
