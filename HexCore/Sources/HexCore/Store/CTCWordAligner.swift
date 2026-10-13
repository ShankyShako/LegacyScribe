import Foundation

/// Word timings for a known transcript: CTC forced alignment (Viterbi) of the transcript's tokens against a
/// CTC model's per-frame log probabilities.
///
/// Not used by the app: with FluidAudio's Parakeet CTC 110M (blank-dominant: every frame's argmax is blank)
/// word starts came out a median ~600 ms off on synthesized speech with exact boundaries, against ~50 ms for
/// Parakeet TDT's own timings (`WordMatcher`). Kept for `lsbench align --ctc`, to try a stronger CTC model.
public enum CTCWordAligner {
	public static let defaultStartLead = 0.0

	/// - Parameters:
	///   - words: the transcript split into words, in order.
	///   - logProbs: `[frame][token]` log probabilities from the CTC head.
	///   - frameDuration: seconds per frame.
	///   - blank: the CTC blank token.
	///   - tokenize: a word's token IDs (with its word-boundary marker). Words that come back empty
	///     (pure punctuation, say) get the gap between their neighbours.
	///   - startLead: CTC emits a token as a spike partway into its sound, so a word's first token frame
	///     comes late; its start moves this much earlier, but never before the previous word's end.
	/// - Returns: one timing per word, or nil when the audio has too few frames for the tokens.
	public static func align(
		words: [String],
		logProbs: [[Float]],
		frameDuration: Double,
		blank: Int,
		startLead: Double = defaultStartLead,
		tokenize: (String) -> [Int]
	) -> [SpokenWord]? {
		var tokens: [Int] = []
		var owner: [Int] = []
		for (index, word) in words.enumerated() {
			let ids = tokenize(word).filter { $0 != blank }
			tokens += ids
			owner += Array(repeating: index, count: ids.count)
		}
		guard !words.isEmpty else { return [] }
		guard !tokens.isEmpty, let frames = path(tokens: tokens, logProbs: logProbs, blank: blank) else { return nil }

		// First and last frame of each word, from the frames its tokens hold.
		var first = [Int?](repeating: nil, count: words.count)
		var last = [Int?](repeating: nil, count: words.count)
		for (frame, token) in frames.enumerated() {
			guard let token else { continue }
			let word = owner[token]
			if first[word] == nil { first[word] = frame }
			last[word] = frame
		}

		var timings: [SpokenWord] = []
		for (index, word) in words.enumerated() {
			if let start = first[index], let end = last[index] {
				let spike = Double(start) * frameDuration
				let floor = timings.last?.end ?? 0
				timings.append(SpokenWord(word: word, start: max(floor, spike - startLead), end: Double(end + 1) * frameDuration))
			} else {
				// No tokens of its own: it sits between the previous word's end and the next word's start.
				let start = timings.last?.end ?? 0
				let next = ((index + 1) ..< words.count).lazy.compactMap { first[$0] }.first.map { Double($0) * frameDuration }
				timings.append(SpokenWord(word: word, start: start, end: max(start, next ?? start)))
			}
		}
		return timings
	}

	/// The most likely CTC path that spells `tokens`: for each frame, the index into `tokens` it emits,
	/// or nil for blank. Standard CTC topology: blanks between tokens, a token may repeat across frames,
	/// and a blank is required between two equal adjacent tokens.
	static func path(tokens: [Int], logProbs: [[Float]], blank: Int) -> [Int?]? {
		let frameCount = logProbs.count
		let stateCount = 2 * tokens.count + 1
		// The shortest path needs one frame per token plus one per repeated pair.
		let repeats = zip(tokens, tokens.dropFirst()).filter { $0 == $1 }.count
		guard frameCount >= tokens.count + repeats else { return nil }

		func label(_ state: Int) -> Int { state % 2 == 0 ? blank : tokens[state / 2] }
		func emission(_ frame: Int, _ state: Int) -> Float {
			let row = logProbs[frame]
			let id = label(state)
			return id < row.count ? row[id] : -.infinity
		}

		let impossible = -Float.infinity
		var score = [Float](repeating: impossible, count: stateCount)
		// Back pointers: how far back (0, 1 or 2 states) each state came from, per frame.
		var back = [[UInt8]](repeating: [UInt8](repeating: 0, count: stateCount), count: frameCount)
		score[0] = emission(0, 0)
		if stateCount > 1 { score[1] = emission(0, 1) }

		for frame in 1 ..< max(frameCount, 1) {
			var next = [Float](repeating: impossible, count: stateCount)
			// A state can only be reached if enough frames remain for the rest of the tokens; skipping
			// that pruning keeps the code simple and costs little at dictation lengths.
			for state in 0 ..< stateCount {
				var best = score[state]
				var step: UInt8 = 0
				if state >= 1, score[state - 1] > best {
					best = score[state - 1]
					step = 1
				}
				if state >= 2, state % 2 == 1, tokens[state / 2] != tokens[state / 2 - 1], score[state - 2] > best {
					best = score[state - 2]
					step = 2
				}
				guard best > impossible else { continue }
				next[state] = best + emission(frame, state)
				back[frame][state] = step
			}
			score = next
		}

		// End in the last token or the trailing blank.
		var state = stateCount - 1
		if stateCount >= 2, score[stateCount - 2] > score[stateCount - 1] { state = stateCount - 2 }
		guard score[state] > impossible else { return nil }

		var frames = [Int?](repeating: nil, count: frameCount)
		for frame in stride(from: frameCount - 1, through: 0, by: -1) {
			frames[frame] = state % 2 == 1 ? state / 2 : nil
			state -= Int(back[frame][state])
		}
		return frames
	}
}
