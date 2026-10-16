import Foundation

/// One run of the filler-free minute: talk for 60 s on a topic the app picks, then see the fillers counted.
/// The recording itself isn't kept past the result screen; this is what stays.
public struct CoachMinute: Codable, Equatable, Identifiable, Sendable {
	public static let seconds = 60.0

	public var id: UUID
	public var date: Date
	public var topic: String
	public var engine: String
	/// What the engine heard, ums included, for the result screen.
	public var text: String
	public var words: Int
	public var speakingSeconds: Double
	public var fillers: [String: Int]
	public var crutches: [String: Int]
	public var hedges: [String: Int]
	/// Semitones (`PitchTracker`); nil when there was too little voiced speech.
	public var pitchRange: Double?

	public init(
		id: UUID = UUID(), date: Date, topic: String, engine: String, text: String = "", words: Int, speakingSeconds: Double,
		fillers: [String: Int] = [:], crutches: [String: Int] = [:], hedges: [String: Int] = [:], pitchRange: Double? = nil
	) {
		self.id = id
		self.date = date
		self.topic = topic
		self.engine = engine
		self.text = text
		self.words = words
		self.speakingSeconds = speakingSeconds
		self.fillers = fillers
		self.crutches = crutches
		self.hedges = hedges
		self.pitchRange = pitchRange
	}

	public var fillerCount: Int { fillers.values.reduce(0, +) }
	public var crutchCount: Int { crutches.values.reduce(0, +) }
	public var hedgeCount: Int { hedges.values.reduce(0, +) }
	public var wordsPerMinute: Double? { speakingSeconds >= 5 ? Double(words) / speakingSeconds * 60 : nil }

	/// The result of one run from its timed words and samples.
	public static func score(
		topic: String, engine: String, words: [SpokenWord], samples: [Float], sampleRate: Double, date: Date = Date()
	) -> CoachMinute {
		let text = CoachText.analyse(words.map(\.word))
		let speaking = max(0, (words.last?.end ?? 0) - (words.first?.start ?? 0))
		return CoachMinute(
			date: date, topic: topic, engine: engine, text: words.map(\.word).joined(separator: " "), words: text.words,
			speakingSeconds: speaking,
			fillers: text.fillers.reduce(into: [:]) { $0[$1.kind.rawValue, default: 0] += 1 },
			crutches: text.crutches.reduce(into: [:]) { $0[$1.kind.rawValue, default: 0] += 1 },
			hedges: text.hedges.reduce(into: [:]) { $0[$1.kind.rawValue, default: 0] += 1 },
			pitchRange: PitchTracker.semitoneRange(samples: samples, sampleRate: sampleRate)
		)
	}

	/// The best run: fewest fillers, then the most words (talking more without them is harder). Runs with
	/// under 60 words don't count: saying little is an easy way to say no "um".
	public static func best(of runs: [CoachMinute]) -> CoachMinute? {
		runs.filter { $0.words >= 60 }.min { ($0.fillerCount, -$0.words) < ($1.fillerCount, -$1.words) }
	}

	/// Everyday topics anyone can talk about for a minute without preparing.
	public static let topics = [
		"Describe the last meal you cooked, step by step.",
		"Explain how to get from your home to the nearest grocery store.",
		"What would you do with a free Saturday and no obligations?",
		"Describe a teacher who made a difference to you.",
		"Explain a hobby of yours to someone who has never tried it.",
		"What is the best trip you have taken, and why?",
		"Describe your morning routine on a weekday.",
		"Convince a friend to read a book you liked.",
		"Explain how your phone or computer is organised.",
		"What is a skill you would like to learn, and how would you start?",
		"Describe the room you are sitting in to someone who can't see it.",
		"Tell the story of how you met a close friend.",
		"Explain the rules of a game or sport you know well.",
		"What would your perfect workspace look like?",
		"Describe a problem you solved recently and how you did it.",
		"What is a small change that made your life easier?",
		"Explain a recipe or drink you could make with your eyes closed.",
		"Describe the town or city you grew up in.",
		"What advice would you give to yourself five years ago?",
		"Explain how to look after a plant or a pet.",
		"Describe a film or show you'd recommend, without spoiling it.",
		"What does a good weekend look like for you?",
		"Explain something you know a lot about to a ten-year-old.",
		"Describe the best gift you have given someone.",
		"What would you change about your daily commute?",
		"Talk about a place you'd like to visit and what you'd do there.",
		"Describe how you would plan a birthday party for a friend.",
		"Explain why you chose your field of study or your job.",
		"What is something most people don't know about you?",
		"Describe a time something went wrong and what you learned from it.",
	]
}
