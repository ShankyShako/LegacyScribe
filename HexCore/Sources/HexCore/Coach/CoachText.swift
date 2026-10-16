import Foundation

/// Fillers and self-corrections in a verbatim transcript (Parakeet or Apple Speech, which write the user's
/// ums; Cohere doesn't). Word lists keep the engine's punctuation, which the correction rules rely on.
public enum CoachText {
	public enum Filler: String, CaseIterable, Sendable {
		case um, uh, er, ah, hmm
	}

	/// Kept narrow on purpose: "no" and "actually" count only between commas mid-sentence ("two, no, three"),
	/// because a sentence that starts with them is usually an answer, not a correction.
	public enum Correction: String, CaseIterable, Sendable {
		case iMean = "i mean"
		case scratchThat = "scratch that"
		case no
		case sorry
		case wait
		case actually
		/// The same word twice in a row ("the the"): a restart.
		case repeated
	}

	/// Words leaned on to fill or soften a sentence. Each has ordinary uses too ("I like it", "what kind of
	/// car"), so the rules count only the filler use and leave a doubtful one out.
	public enum Crutch: String, CaseIterable, Sendable {
		case just, like, basically, literally
		case youKnow = "you know"
		case kindOf = "kind of"
		case sortOf = "sort of"
		case right = "right?"
		/// "So" or "Oh" opening a sentence ("So, I went…", "Oh, then there is…"): a run-up to the sentence.
		case so = "so…"
		case oh = "oh…"
	}

	/// Phrases that soften a claim. Not mistakes: shown so the user sees how often they hedge.
	public enum Hedge: String, CaseIterable, Sendable {
		case iThink = "i think"
		case maybe
		case iGuess = "i guess"
		case iSuppose = "i suppose"
		case perhaps
		case iFeelLike = "i feel like"
	}

	/// A sentence this long that chains clauses with "and" reads as a run-on. Counted from the engine's full
	/// stops, which follow the speaker's pauses, so the "and"s carry the weight.
	public static let runOnWords = 40
	public static let runOnAnds = 3

	public struct Sentence: Equatable, Sendable {
		/// Index of its first word in the word list.
		public var start: Int
		/// Index of its last word.
		public var end: Int
		/// Spoken words, fillers left out.
		public var words: Int
		public var ands: Int
		public var isRunOn: Bool { words >= CoachText.runOnWords && ands >= CoachText.runOnAnds }
	}

	/// Each finding with the index of its (first) word in the word list, so it can be found in the audio.
	public struct Result: Sendable {
		public var words: Int
		public var fillers: [(index: Int, kind: Filler)]
		public var corrections: [(index: Int, kind: Correction)]
		public var crutches: [(index: Int, kind: Crutch)] = []
		public var hedges: [(index: Int, kind: Hedge)] = []
		public var sentences: [Sentence] = []
	}

	public static func filler(_ word: String) -> Filler? {
		switch bare(word) {
		case "um", "umm", "ummm", "uhm", "uhmm": .um
		case "uh", "uhh", "uhhh": .uh
		case "er", "erm", "err": .er
		case "ah", "ahh", "ahhh": .ah
		case "hmm", "hmmm", "hm", "mm", "mmm": .hmm
		default: nil
		}
	}

	/// Words that are often said twice on purpose ("had had", "that that", "no no").
	static let allowedRepeats: Set<String> = ["had", "that", "no", "yeah", "yes", "bye", "ha", "very", "so", "really", "many", "much"]

	/// A phrase of up to 5 words said again at once ("you can you can"), after a cut-off word ("I w I was",
	/// "their m their mind": the start of the word repeated or of the one after it) or, for 2+ words, after
	/// one other word ("if you want to do if you want to"). The index of each restart's first word. A gap
	/// word closing a clause with a comma is a list ("how many are online, how many are viewing"), and a
	/// whole word between two of the same ("one by one") isn't cut off. Single words said twice in a row are
	/// counted apart.
	static func restarts(_ spoken: [(index: Int, bare: String)], words: [String]) -> [Int] {
		var found: [Int] = []
		var position = 0
		while position < spoken.count {
			var skip = 1
			search: for length in 1 ... 5 {
				for gap in 0 ... 1 where length > 1 || gap == 1 {
					let second = position + length + gap
					guard second + length <= spoken.count else { continue }
					guard (0 ..< length).allSatisfy({ spoken[position + $0].bare == spoken[second + $0].bare }) else { continue }
					if gap == 1 {
						let between = spoken[position + length]
						guard let last = words[between.index].last, last.isLetter || last.isNumber || last == "'" else { continue }
						if length == 1 {
							let after = second + 1 < spoken.count ? spoken[second + 1].bare : ""
							let cutOff = between.bare.count < spoken[second].bare.count && spoken[second].bare.hasPrefix(between.bare)
								|| between.bare.count < after.count && after.hasPrefix(between.bare)
							guard cutOff else { continue }
						}
					}
					if length == 1, allowedRepeats.contains(spoken[position].bare) { continue }
					found.append(spoken[position].index)
					skip = length + gap
					break search
				}
			}
			position += skip
		}
		return found
	}

	public static func analyse(_ words: [String]) -> Result {
		var fillers: [(index: Int, kind: Filler)] = []
		var corrections: [(index: Int, kind: Correction)] = []
		var spoken: [(index: Int, bare: String)] = []
		for (index, word) in words.enumerated() {
			if let kind = filler(word) {
				fillers.append((index, kind))
			} else if !bare(word).isEmpty {
				spoken.append((index, bare(word)))
			}
		}

		for (position, word) in spoken.enumerated() where position > 0 {
			let previous = spoken[position - 1]
			if word.bare == previous.bare, !allowedRepeats.contains(word.bare), Double(word.bare) == nil {
				corrections.append((previous.index, .repeated))
			}
		}
		corrections += restarts(spoken, words: words).map { ($0, .repeated) }
		corrections.sort { $0.index < $1.index }

		for (index, word) in words.enumerated() {
			let lower = bare(word)
			let previous = index > 0 ? words[index - 1] : nil
			let next = index + 1 < words.count ? words[index + 1] : nil
			// Mid-sentence and set off by a comma: "two, no, three", "the red, sorry, the blue one".
			let setOff = previous.map { $0.hasSuffix(",") } == true && word.hasSuffix(",")
			switch lower {
			case "no" where setOff: corrections.append((index, .no))
			case "sorry" where setOff: corrections.append((index, .sorry))
			case "actually" where setOff: corrections.append((index, .actually))
			case "wait" where previous.map { $0.hasSuffix(",") || bare($0) == "no" } == true: corrections.append((index, .wait))
			case "i" where next.map(bare) == "mean" && (previous == nil || previous!.hasSuffix(",") || previous!.hasSuffix(".")):
				// "I mean" opening a clause; "what I mean is" doesn't count.
				corrections.append((index, .iMean))
			case "scratch" where next.map(bare) == "that": corrections.append((index, .scratchThat))
			default: break
			}
		}

		var result = Result(words: spoken.count, fillers: fillers, corrections: corrections)
		result.crutches = crutches(in: words)
		result.hedges = hedges(in: words)
		result.sentences = sentences(in: words)
		return result
	}

	/// Words "like" follows in its ordinary uses: "I like", "would like", "looks like", "just like".
	static let likeIsOrdinaryAfter: Set<String> = [
		"i", "you", "we", "they", "he", "she", "would", "i'd", "you'd", "we'd", "they'd", "don't", "didn't", "doesn't",
		"feel", "feels", "felt", "look", "looks", "looked", "sound", "sounds", "sounded", "seem", "seems", "something",
		"anything", "nothing", "really", "also", "just", "much", "more", "exactly", "not",
	]
	/// "you know" after these is a real question or clause: "do you know", "if you know".
	static let youKnowIsOrdinaryAfter: Set<String> = ["do", "did", "don't", "didn't", "if", "as", "would", "what", "how", "whether"]
	/// "kind of"/"sort of" after these names a kind: "what kind of car", "a sort of tool".
	static let kindIsANounAfter: Set<String> = [
		"what", "what's", "this", "that", "a", "the", "some", "any", "which", "every", "same", "different", "one",
		"each", "no", "these", "those", "all", "other", "another", "new", "right", "wrong",
	]

	/// "So" opening a sentence is a real word before these: "So far", "So do I", "So that's it" is left in
	/// (its bare form is "that's").
	static let soIsOrdinaryBefore: Set<String> = [
		"far", "much", "many", "long", "few", "little", "that", "to", "is", "was", "are", "were", "am", "do", "does",
		"did", "can", "could", "will", "would", "should", "have", "has", "had",
	]

	static func crutches(in words: [String]) -> [(index: Int, kind: Crutch)] {
		var found: [(index: Int, kind: Crutch)] = []
		for (index, word) in words.enumerated() {
			let lower = bare(word)
			let previous = index > 0 ? bare(words[index - 1]) : nil
			let next = index + 1 < words.count ? words[index + 1] : nil
			// The word before, fillers skipped, closes a sentence (or there is none).
			func opensSentence() -> Bool {
				words[..<index].last { filler($0) == nil && !bare($0).isEmpty }.map { ".?!".contains($0.last!) } ?? true
			}
			switch lower {
			case "so" where opensSentence() && !soIsOrdinaryBefore.contains(next.map(bare) ?? ""):
				found.append((index, .so))
			case "oh" where opensSentence():
				found.append((index, .oh))
			case "just" where !["in", "as", "now"].contains(next.map(bare) ?? ""):
				found.append((index, .just))
			// Only the use set off by a comma ("it's, like, broken"): "like" without commas is too often a verb
			// or a comparison to call.
			case "like" where word.hasSuffix(",") && !likeIsOrdinaryAfter.contains(previous ?? ""):
				found.append((index, .like))
			case "basically": found.append((index, .basically))
			case "literally": found.append((index, .literally))
			case "you" where next.map(bare) == "know" && next.map { $0.hasSuffix(",") || $0.hasSuffix("?") || $0.hasSuffix(".") } == true
				&& !youKnowIsOrdinaryAfter.contains(previous ?? ""):
				found.append((index, .youKnow))
			case "kind" where next.map(bare) == "of" && !kindIsANounAfter.contains(previous ?? ""):
				found.append((index, .kindOf))
			case "sort" where next.map(bare) == "of" && !kindIsANounAfter.contains(previous ?? ""):
				found.append((index, .sortOf))
			case "right" where index > 0 && word.hasSuffix("?"):
				found.append((index, .right))
			default: break
			}
		}
		return found
	}

	static func hedges(in words: [String]) -> [(index: Int, kind: Hedge)] {
		var found: [(index: Int, kind: Hedge)] = []
		for (index, word) in words.enumerated() {
			let next = index + 1 < words.count ? bare(words[index + 1]) : nil
			let afterNext = index + 2 < words.count ? bare(words[index + 2]) : nil
			switch bare(word) {
			// "I think of"/"I think about" is thinking, not hedging.
			case "i" where next == "think" && !["of", "about"].contains(afterNext ?? ""): found.append((index, .iThink))
			case "i" where next == "guess": found.append((index, .iGuess))
			case "i" where next == "suppose": found.append((index, .iSuppose))
			case "i" where next == "feel" && afterNext == "like": found.append((index, .iFeelLike))
			case "maybe": found.append((index, .maybe))
			case "perhaps": found.append((index, .perhaps))
			default: break
			}
		}
		return found
	}

	/// Sentences split at the engine's full stops, question and exclamation marks.
	static func sentences(in words: [String]) -> [Sentence] {
		var sentences: [Sentence] = []
		var current: Sentence?
		for (index, word) in words.enumerated() {
			if filler(word) == nil, !bare(word).isEmpty {
				if current == nil { current = Sentence(start: index, end: index, words: 0, ands: 0) }
				current!.end = index
				current!.words += 1
				if bare(word) == "and" { current!.ands += 1 }
			}
			if let last = word.last, ".?!".contains(last), let sentence = current {
				sentences.append(sentence)
				current = nil
			}
		}
		if let current { sentences.append(current) }
		return sentences
	}

	/// Lowercased, without surrounding punctuation.
	static func bare(_ word: String) -> String {
		word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
	}
}
