import Foundation

/// What the recorded lines cover so far.
public struct PracticeCoverage: Equatable, Sendable {
	public var soundCounts: [String: Int] = [:]
	public var pairs: Set<String> = []
	public var terms: Set<String> = []

	public init() {}

	public init(_ lines: some Sequence<PracticeLine>) {
		for line in lines {
			add(line)
		}
	}

	public mutating func add(_ line: PracticeLine) {
		soundCounts.merge(line.sounds, uniquingKeysWith: +)
		pairs.formUnion(line.pairs)
		terms.formUnion(line.terms)
	}

	/// Distinct sounds recorded at least once.
	public var soundsCovered: Int { soundCounts.count }
}

/// A line in a session and the slot it fills there.
public struct PracticePick: Equatable, Identifiable, Sendable {
	public var role: PracticeLine.Stage
	public var line: PracticeLine

	public init(role: PracticeLine.Stage, line: PracticeLine) {
		self.role = role
		self.line = line
	}

	public var id: String { line.id }
}

/// Picks short practice sets from the script: a few lines for the sounds recorded least, one to three
/// for unrecorded sound pairs, one or two of the user's own jargon, and one ordinary line. Lines never
/// shown come first; each pick is drawn from the best few, so no two sets are alike.
public enum PracticePicker {
	public static let maxSetSize = 10
	/// How many of the best-scoring lines a pick is drawn from.
	static let drawFrom = 3
	/// Endless mode's slot rotation.
	static let endlessCycle: [PracticeLine.Stage] = [.sounds, .pairs, .sounds, .detail, .pairs, .extra]

	/// Slots for one set: 3–5 sounds, 1–3 pairs, 1–2 detail, 1 extra, at most `maxSetSize`.
	public static func setSlots(using rng: inout some RandomNumberGenerator) -> [PracticeLine.Stage] {
		var sounds = Int.random(in: 3 ... 5, using: &rng)
		var pairs = Int.random(in: 1 ... 3, using: &rng)
		let detail = Int.random(in: 1 ... 2, using: &rng)
		while sounds + pairs + detail + 1 > maxSetSize {
			if pairs > 1 { pairs -= 1 } else { sounds -= 1 }
		}
		return Array(repeating: .sounds, count: sounds)
			+ Array(repeating: .pairs, count: pairs)
			+ Array(repeating: .detail, count: detail)
			+ [.extra]
	}

	public static func pickSet(
		script: PracticeScript,
		log: PracticeLog,
		using rng: inout some RandomNumberGenerator
	) -> [PracticePick] {
		var draft = Draft(script: script, log: log, excluding: [])
		return setSlots(using: &rng).compactMap { draft.pick($0, using: &rng) }
	}

	/// The next line in endless mode, after the lines already in this session.
	public static func pickNext(
		script: PracticeScript,
		log: PracticeLog,
		after picks: [PracticePick],
		using rng: inout some RandomNumberGenerator
	) -> PracticePick? {
		var draft = Draft(script: script, log: log, excluding: Set(picks.map(\.id)))
		for pick in picks {
			draft.coverage.add(pick.line)
		}
		return draft.pick(endlessCycle[picks.count % endlessCycle.count], using: &rng)
	}

	/// How much a line adds in a slot, given what's covered.
	static func score(_ line: PracticeLine, for role: PracticeLine.Stage, coverage: PracticeCoverage) -> Double {
		let words = Double(line.wordCount)
		let newPairs = Double(line.pairs.filter { !coverage.pairs.contains($0) }.count)
		switch role {
		case .sounds:
			// Rare sounds weigh most; a sound repeated within the line counts twice at most.
			let weight = line.sounds.reduce(0.0) { total, sound in
				total + Double(min(sound.value, 2)) / Double(1 + coverage.soundCounts[sound.key, default: 0])
			}
			return weight / words.squareRoot()
		case .pairs:
			return newPairs / words
		case .detail:
			let newTerms = Double(line.terms.filter { !coverage.terms.contains($0) }.count)
			return (newPairs + 3 * newTerms) / words.squareRoot()
		case .extra:
			return 1
		}
	}

	struct Draft {
		var coverage: PracticeCoverage
		/// Lines not recorded and not picked yet.
		var open: [PracticeLine]
		let log: PracticeLog

		init(script: PracticeScript, log: PracticeLog, excluding: Set<String>) {
			self.log = log
			coverage = log.coverage(in: script)
			open = script.lines.filter { log.recordings[$0.id] == nil && !excluding.contains($0.id) }
		}

		mutating func pick(_ role: PracticeLine.Stage, using rng: inout some RandomNumberGenerator) -> PracticePick? {
			// Lines never shown first; once every line has been shown, skipped ones come back.
			let fresh = open.filter { !log.hasSeen($0.id) }
			let pool = fresh.isEmpty ? open : fresh
			guard !pool.isEmpty else { return nil }

			let fitting = pool.filter { fits($0, role) }
			let candidates = fitting.isEmpty ? pool : fitting
			let ranked = candidates
				.map { (line: $0, score: PracticePicker.score($0, for: role, coverage: coverage)) }
				.sorted { $0.score != $1.score ? $0.score > $1.score : $0.line.id < $1.line.id }
			let top = role == .extra ? ranked : Array(ranked.prefix(PracticePicker.drawFrom))
			guard let chosen = top.randomElement(using: &rng)?.line else { return nil }

			open.removeAll { $0.id == chosen.id }
			coverage.add(chosen)
			return PracticePick(role: role, line: chosen)
		}

		func fits(_ line: PracticeLine, _ role: PracticeLine.Stage) -> Bool {
			switch role {
			case .sounds, .pairs: line.stage != .detail
			case .detail: line.stage == .detail
			case .extra: line.stage == .extra
			}
		}
	}
}
