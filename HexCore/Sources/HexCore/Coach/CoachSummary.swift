import Foundation

/// What the Coach tab shows: the analysed dictations added up overall, per week, per mode and per app,
/// with rule-based tips.
public struct CoachSummary: Equatable, Sendable {
	public struct Rates: Equatable, Sendable {
		public var dictations = 0
		public var words = 0
		public var fillers = 0
		public var corrections = 0
		public var speakingSeconds = 0.0
		public var sentencePauses: [Double] = []
		public var thoughtPauses: [Double] = []
		public var crutches = 0
		public var hedges = 0
		public var sentenceLengths: [Int] = []
		public var runOns = 0

		public var fillersPer100Words: Double? { words > 0 ? Double(fillers) * 100 / Double(words) : nil }
		public var correctionsPer100Words: Double? { words > 0 ? Double(corrections) * 100 / Double(words) : nil }
		/// Pauses included: how fast the words arrive.
		public var wordsPerMinute: Double? { speakingSeconds >= 5 ? Double(words) / speakingSeconds * 60 : nil }
		/// Pauses left out: how fast the user talks while talking (articulation rate). Dictation is mostly
		/// thinking aloud, so the rate with pauses says more about thinking than about speaking.
		public var speakingWordsPerMinute: Double? {
			let talking = speakingSeconds - (sentencePauses + thoughtPauses).reduce(0, +)
			return talking >= 5 ? Double(words) / talking * 60 : nil
		}
		/// Medians, because one stop to think (10 s and more happen) would swamp an average.
		public var medianSentencePause: Double? { median(sentencePauses) }
		public var medianThoughtPause: Double? { median(thoughtPauses) }
		public var longestPause: Double? { (sentencePauses + thoughtPauses).max() }
		public var crutchesPer100Words: Double? { words > 0 ? Double(crutches) * 100 / Double(words) : nil }
		public var hedgesPer100Words: Double? { words > 0 ? Double(hedges) * 100 / Double(words) : nil }
		public var medianSentenceLength: Double? { median(sentenceLengths.map(Double.init)) }

		private func median(_ values: [Double]) -> Double? {
			guard !values.isEmpty else { return nil }
			let sorted = values.sorted()
			let middle = sorted.count / 2
			return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
		}

		mutating func add(_ clip: CoachClip) {
			dictations += 1
			words += clip.words
			fillers += clip.fillerCount
			corrections += clip.correctionCount
			speakingSeconds += clip.speakingSeconds
			sentencePauses += clip.sentencePauses
			thoughtPauses += clip.thoughtPauses
			crutches += clip.crutches.values.reduce(0, +)
			hedges += clip.hedges.values.reduce(0, +)
			sentenceLengths += clip.sentenceLengths
			runOns += clip.runOns
		}
	}

	public struct Count: Equatable, Sendable {
		public var name: String
		public var count: Int
	}

	public struct Group: Equatable, Sendable {
		public var name: String
		public var rates: Rates
	}

	public struct Week: Equatable, Sendable {
		public var start: Date
		public var rates: Rates
	}

	public struct Misheard: Equatable, Sendable {
		public var said: String
		public var heard: String
		public var count: Int
	}

	/// A moment to play back, and the dictation whose recording it's in.
	public struct Example: Equatable, Sendable {
		public var dictationID: UUID
		public var date: Date
		public var moment: CoachMoment
	}

	public var overall = Rates()
	/// Most frequent first.
	public var fillers: [Count] = []
	public var corrections: [Count] = []
	/// Share of fillers said in the first `openingSeconds` of a dictation.
	public var openingFillerShare: Double?
	/// Oldest first.
	public var weeks: [Week] = []
	/// Most words first.
	public var byMode: [Group] = []
	public var byApp: [Group] = []
	/// Most frequent first.
	public var crutches: [Count] = []
	public var hedges: [Count] = []
	/// Run-on sentences in the last `recentDays` days.
	public var recentRunOns = 0
	/// Most frequent first, the user's vocabulary left out.
	public var misheard: [Misheard] = []
	/// Every playable moment, newest dictation first.
	public var examples: [Example] = []
	public var tips: [String] = []
	/// Repeats and pauses inside sentences aren't counted against the user, and the pace and pause tips are
	/// left out: for someone who stutters they're how the speech goes, not a habit to coach.
	public var stutterFriendly = false

	public static let openingSeconds = 2.0
	/// Below this the numbers say too little for a tip.
	public static let minimumWordsForTips = 200
	public static let recentDays = 7

	public init() {}

	public init(
		_ clips: [CoachClip],
		calendar: Calendar = .current,
		now: Date = Date(),
		stutterFriendly: Bool = false,
		vocabulary: [String] = []
	) {
		self.stutterFriendly = stutterFriendly
		var fillerCounts: [String: Int] = [:]
		var correctionCounts: [String: Int] = [:]
		var crutchCounts: [String: Int] = [:]
		var hedgeCounts: [String: Int] = [:]
		var misheardCounts: [String: Misheard] = [:]
		let recentStart = now.addingTimeInterval(-Double(Self.recentDays) * 86400)
		var weeks: [Date: Rates] = [:]
		var modes: [String: Rates] = [:]
		var apps: [String: Rates] = [:]
		var opening = 0
		// A recording in which the engine heard no words says nothing about how the user speaks.
		for var clip in clips where clip.words > 0 {
			if stutterFriendly {
				clip.corrections[CoachText.Correction.repeated.rawValue] = nil
				clip.thoughtPauses = []
				clip.moments.removeAll { $0.kind == .pause || $0.label == CoachText.Correction.repeated.rawValue }
			}
			overall.add(clip)
			crutchCounts.merge(clip.crutches, uniquingKeysWith: +)
			hedgeCounts.merge(clip.hedges, uniquingKeysWith: +)
			if clip.date >= recentStart { recentRunOns += clip.runOns }
			for pair in clip.misheard {
				let key = pair.said.lowercased() + "\u{0}" + pair.heard.lowercased()
				misheardCounts[key, default: Misheard(said: pair.said, heard: pair.heard, count: 0)].count += 1
			}
			examples += clip.moments.map { Example(dictationID: clip.dictationID, date: clip.date, moment: $0) }
			fillerCounts.merge(clip.fillers, uniquingKeysWith: +)
			correctionCounts.merge(clip.corrections, uniquingKeysWith: +)
			opening += clip.fillerOffsets.filter { $0 < Self.openingSeconds }.count
			if let week = calendar.dateInterval(of: .weekOfYear, for: clip.date)?.start {
				weeks[week, default: Rates()].add(clip)
			}
			modes[clip.mode ?? "raw", default: Rates()].add(clip)
			apps[clip.appName ?? "Unknown app", default: Rates()].add(clip)
		}
		let counts = { (counts: [String: Int]) in
			counts.filter { $0.value > 0 }.map { Count(name: $0.key, count: $0.value) }
				.sorted { ($0.count, $1.name) > ($1.count, $0.name) }
		}
		let groups = { (groups: [String: Rates]) in
			groups.map { Group(name: $0.key, rates: $0.value) }.sorted { ($0.rates.words, $1.name) > ($1.rates.words, $0.name) }
		}
		fillers = counts(fillerCounts)
		corrections = counts(correctionCounts)
		openingFillerShare = overall.fillers > 0 ? Double(opening) / Double(overall.fillers) : nil
		self.weeks = weeks.map { Week(start: $0.key, rates: $0.value) }.sorted { $0.start < $1.start }
		byMode = groups(modes)
		byApp = groups(apps)
		crutches = counts(crutchCounts)
		hedges = counts(hedgeCounts)
		let known = Set(vocabulary.map { $0.lowercased() })
		misheard = misheardCounts.values.filter { !known.contains($0.said.lowercased()) }
			.sorted { ($0.count, $1.said) > ($1.count, $0.said) }
		examples.sort { $0.date != $1.date ? $0.date > $1.date : $0.moment.time < $1.moment.time }
		tips = Self.tips(for: self)
	}

	/// Rule-based, strongest signal first. Thresholds are rough conversational norms: fillers run at about
	/// 1–3 per 100 words in everyday speech, and people articulate at roughly 150–200 words a minute.
	static func tips(for summary: CoachSummary) -> [String] {
		let overall = summary.overall
		guard overall.words >= minimumWordsForTips else {
			return ["Dictate a little more before the tips mean much: there are \(overall.words) words so far, and they start at \(minimumWordsForTips)."]
		}
		var tips: [String] = []
		if let rate = overall.fillersPer100Words, rate >= 2, let top = summary.fillers.first {
			tips.append(String(
				format: "You say a filler about %.1f times per 100 words, “%@” most. When you feel one coming, stop for a beat instead: a silent pause sounds surer than a filler.",
				rate, top.name
			))
		}
		if let share = summary.openingFillerShare, overall.fillers >= 5, share >= 0.4 {
			tips.append(String(
				format: "%.0f%% of your fillers come in the first two seconds. Know your first sentence before you press the key, then start.",
				share * 100
			))
		}
		if let rate = overall.correctionsPer100Words, rate >= 1.5 {
			tips.append(String(
				format: "You correct yourself about %.1f times per 100 words. LegacyScribe keeps only the corrected version, but a moment to plan the sentence saves the restart.",
				rate
			))
		}
		if let rate = overall.crutchesPer100Words, rate >= 1, let top = summary.crutches.first {
			tips.append(String(
				format: "“%@” shows up %.1f times per 100 words. Read back one dictation and cut every “%@”: most go without changing the meaning.",
				top.name.capitalizedFirst, Double(top.count) * 100 / Double(overall.words), top.name
			))
		}
		if overall.runOns >= 3, Double(overall.runOns) / Double(max(overall.sentenceLengths.count, 1)) >= 0.05 {
			tips.append(String(
				format: "%d of your sentences run %d+ words joined by “and”. Stop where the “and” would be and start a new sentence.",
				overall.runOns, CoachText.runOnWords
			))
		}
		if !summary.stutterFriendly, let pace = overall.speakingWordsPerMinute {
			if pace > 210 {
				tips.append(String(format: "Between pauses you speak at about %.0f words a minute, on the fast side. Slowing a little gives the engine cleaner words.", pace))
			} else if pace < 110 {
				tips.append(String(format: "Between pauses you speak at about %.0f words a minute, which is slow. Saying each thought in one go reads better and dictates faster.", pace))
			}
		}
		if !summary.stutterFriendly, let thought = overall.medianThoughtPause, thought >= 0.8 {
			tips.append(String(format: "Your typical pause inside a sentence lasts %.1f s. Long mid-sentence pauses usually mean planning while talking; try finishing the thought before you speak.", thought))
		}
		if tips.isEmpty {
			tips.append("Nothing stands out: your fillers, corrections and pace are all in an easy range.")
		}
		return tips
	}
}

private extension String {
	var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
