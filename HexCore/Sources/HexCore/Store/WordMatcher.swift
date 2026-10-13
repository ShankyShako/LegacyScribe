import Foundation

/// Moves word timings from one transcript of a recording onto another transcript of the same recording,
/// e.g. Parakeet TDT's timed words onto the words Cohere produced. Words are paired by an edit-distance
/// alignment on lowercased, punctuation-free text, so a few disagreements ("three fifteen" against "3:15")
/// stay local instead of shifting every later word.
public enum WordMatcher {
	/// Parakeet TDT starts a word where the previous one ended, inside the pause, so its starts run early;
	/// one 80 ms frame later is closest. `lsbench align --tts` on 879 synthesized words with exact
	/// boundaries: starts median 51 ms off, 77% within 80 ms (72 ms and 55% without the shift).
	public static let tdtStartShift = 0.08

	/// `startShift` moves each word's start later (never past its end).
	public static func transfer(_ heard: [SpokenWord], onto target: [String], startShift: Double = 0) -> [SpokenWord] {
		guard !heard.isEmpty else { return [] }
		let a = target.map(normalized)
		let b = heard.map { normalized($0.word) }
		let n = a.count, m = b.count

		// cost[i][j]: aligning the first i target words with the first j heard words.
		var cost = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
		for i in 0 ... n { cost[i][0] = i }
		for j in 0 ... m { cost[0][j] = j }
		if n > 0, m > 0 {
			for i in 1 ... n {
				for j in 1 ... m {
					let pair = cost[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
					cost[i][j] = min(pair, cost[i - 1][j] + 1, cost[i][j - 1] + 1)
				}
			}
		}

		// Walk back: which heard words each target word got (a substitution keeps its partner; heard words
		// with no target partner widen the target word before them).
		var partners = [[Int]](repeating: [], count: n)
		var i = n, j = m
		var pendingExtra: [Int] = []
		// On ties: an exact match first, then an extra heard word, then a substitution, so "3:15" against
		// "three fifteen" pairs with "three" and takes "fifteen" along rather than leaving "three" behind.
		while i > 0 || j > 0 {
			let exact = i > 0 && j > 0 && a[i - 1] == b[j - 1] && cost[i][j] == cost[i - 1][j - 1]
			if exact || (i > 0 && j > 0 && !(j > 0 && cost[i][j] == cost[i][j - 1] + 1) && cost[i][j] == cost[i - 1][j - 1] + 1) {
				partners[i - 1] = [j - 1] + pendingExtra
				pendingExtra = []
				i -= 1
				j -= 1
			} else if j > 0, cost[i][j] == cost[i][j - 1] + 1 {
				pendingExtra.insert(j - 1, at: 0)
				j -= 1
			} else {
				i -= 1
			}
		}
		// Extra heard words before the first matched target word belong to it.
		if !pendingExtra.isEmpty, let first = partners.firstIndex(where: { !$0.isEmpty }) {
			partners[first] = pendingExtra + partners[first]
		}

		var timings: [SpokenWord] = []
		for (index, word) in target.enumerated() {
			if let first = partners[index].min(), let last = partners[index].max() {
				let end = heard[last].end
				timings.append(SpokenWord(word: word, start: min(end, heard[first].start + startShift), end: end))
			} else {
				// Nothing heard for it: the gap between its neighbours.
				let start = timings.last?.end ?? heard[0].start
				let next = partners[(index + 1)...].lazy.compactMap { $0.min() }.first.map { heard[$0].start }
				timings.append(SpokenWord(word: word, start: start, end: max(start, next ?? start)))
			}
		}
		return timings
	}

	/// Words from subword pieces with times (Parakeet TDT's tokens): a piece starting with a space or
	/// SentencePiece's "▁" begins a word.
	public static func words(fromPieces pieces: [(text: String, start: Double, end: Double)]) -> [SpokenWord] {
		var words: [SpokenWord] = []
		for piece in pieces {
			let starts = piece.text.hasPrefix(" ") || piece.text.hasPrefix("▁")
			let text = String(piece.text.drop(while: { $0 == " " || $0 == "▁" }))
			if starts || words.isEmpty {
				words.append(SpokenWord(word: text, start: piece.start, end: piece.end))
			} else {
				words[words.count - 1].word += text
				words[words.count - 1].end = piece.end
			}
		}
		return words.filter { !$0.word.isEmpty }
	}

	static func normalized(_ word: String) -> String {
		String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
	}
}
