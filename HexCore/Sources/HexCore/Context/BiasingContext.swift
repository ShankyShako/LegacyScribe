import Foundation

/// Words this dictation should spell a particular way, for the speech engine's biasing hook and the rewrite:
/// the user's vocabulary, spellings they fixed in text they sent, and names from the text around the cursor.
///
/// Each list is already cleaned and ordered (most useful first); `terms(limit:)` merges them for engines
/// that take one capped list.
public struct BiasingContext: Equatable, Sendable {
	/// The user's vocabulary from Settings, in their order.
	public var vocabulary: [String]
	/// Spellings the user fixed before sending (`SentEdit`), newest first.
	public var corrections: [String]
	/// Names and identifiers near the cursor in the focused field, most used first.
	public var nearby: [String]

	public init(vocabulary: [String] = [], corrections: [String] = [], nearby: [String] = []) {
		self.vocabulary = BiasingContext.cleaned(vocabulary)
		self.corrections = BiasingContext.cleaned(corrections)
		self.nearby = BiasingContext.cleaned(nearby)
	}

	public static let empty = BiasingContext()

	/// Builds the context for one dictation. `field` is the focused field's text and the cursor's UTF-16
	/// offset (as Accessibility reports it); nil when nothing readable is focused or context is turned off.
	public static func build(
		vocabulary: [String],
		sentEdits: [SentEdit],
		field: (text: String, cursor: Int?)?
	) -> BiasingContext {
		BiasingContext(
			vocabulary: vocabulary,
			corrections: CorrectionTerms.extract(from: sentEdits),
			nearby: field.map { ContextTerms.extract(from: $0.text, cursorUTF16: $0.cursor) } ?? []
		)
	}

	public var isEmpty: Bool { vocabulary.isEmpty && corrections.isEmpty && nearby.isEmpty }

	/// Terms the rewrite must spell exactly: the vocabulary, then the user's own fixes.
	public var exactTerms: [String] {
		BiasingContext.cleaned(vocabulary + corrections)
	}

	/// Nearby terms not already among `exactTerms`. These are only hints: the dictation may not mention them.
	public var nearbyOnly: [String] {
		let exact = Set(exactTerms.map { $0.lowercased() })
		return nearby.filter { !exact.contains($0.lowercased()) }
	}

	/// Every term in priority order (vocabulary, corrections, nearby) without case-insensitive repeats,
	/// at most `limit`.
	public func terms(limit: Int) -> [String] {
		Array(BiasingContext.cleaned(vocabulary + corrections + nearby).prefix(max(0, limit)))
	}

	/// Trimmed, non-empty, first spelling of each term kept (case-insensitive).
	static func cleaned(_ terms: [String]) -> [String] {
		var seen = Set<String>()
		var result: [String] = []
		for term in terms {
			let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
			result.append(trimmed)
		}
		return result
	}
}

// MARK: - Terms near the cursor

/// Picks the names and identifiers out of the text around the cursor: CamelCase and mixed-case words
/// (SwiftUI, macOS), acronyms (TCA), words with digits or dots (M5, CLAUDE.md), handles and slash commands,
/// and capitalized words that aren't starting a sentence (Syncthing, Claude Code). Ordinary lowercase words
/// are skipped: the speech engine already spells those.
public enum ContextTerms {
	/// Characters read on each side of the cursor. Text further away is less likely to be what the dictation
	/// is about, and a long document must not cost time on every dictation.
	public static let radius = 3000
	public static let maxTerms = 40
	static let maxTermLength = 40

	/// Capitalized words that say nothing about the document.
	static let ignoredWords: Set<String> = [
		"i", "i'm", "i'll", "i've", "i'd", "ok", "okay", "mr", "mrs", "ms", "dr", "st", "am", "pm", "a",
	]

	/// `cursorUTF16` is the insertion point as a UTF-16 offset; nil reads around the end of the text.
	public static func extract(from text: String, cursorUTF16: Int? = nil, limit: Int = maxTerms) -> [String] {
		let (window, cursor) = excerpt(text, cursorUTF16: cursorUTF16)
		let tokens = tokenize(window)

		struct Candidate {
			var spelling: String
			var count: Int
			var distance: Int
		}
		var candidates: [String: Candidate] = [:]
		var order: [String] = []
		func add(_ term: String, at offset: Int) {
			guard term.count <= maxTermLength else { return }
			let key = term.lowercased()
			let distance = abs(offset - cursor)
			if var existing = candidates[key] {
				existing.count += 1
				existing.distance = min(existing.distance, distance)
				candidates[key] = existing
			} else {
				candidates[key] = Candidate(spelling: term, count: 1, distance: distance)
				order.append(key)
			}
		}

		// Runs of adjacent capitalized words become one name ("Visual Studio Code").
		var run: [Token] = []
		func flushRun() {
			guard !run.isEmpty else { return }
			add(run.map(\.text).joined(separator: " "), at: run[0].offset)
			run.removeAll()
		}
		for token in tokens {
			switch token.kind {
			case .shaped:
				flushRun()
				add(token.text, at: token.offset)
			case .name:
				if let last = run.last, last.end == token.offset - 1, run.count < 4 {
					run.append(token)
				} else {
					flushRun()
					run = [token]
				}
			case .plain:
				flushRun()
			}
		}
		flushRun()

		return order
			.compactMap { candidates[$0] }
			.enumerated()
			.sorted { lhs, rhs in
				if lhs.element.count != rhs.element.count { return lhs.element.count > rhs.element.count }
				if lhs.element.distance != rhs.element.distance { return lhs.element.distance < rhs.element.distance }
				return lhs.offset < rhs.offset
			}
			.prefix(max(0, limit))
			.map(\.element.spelling)
	}

	/// The stretch of `text` within `radius` characters of the cursor, cut at whitespace, and the cursor's
	/// character offset inside it.
	static func excerpt(_ text: String, cursorUTF16: Int?, radius: Int = radius) -> (String, Int) {
		let utf16 = text.utf16
		let cursorIndex: String.Index = {
			guard let cursorUTF16, cursorUTF16 >= 0, cursorUTF16 <= utf16.count,
			      let index = utf16.index(utf16.startIndex, offsetBy: cursorUTF16, limitedBy: utf16.endIndex)
			else { return text.endIndex }
			return index.samePosition(in: text) ?? text.endIndex
		}()
		var start = text.index(cursorIndex, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
		var end = text.index(cursorIndex, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
		// Don't start or end inside a word.
		if start != text.startIndex, let space = text[start...].firstIndex(where: \.isWhitespace), space < cursorIndex {
			start = space
		}
		if end != text.endIndex, let space = text[..<end].lastIndex(where: \.isWhitespace), space > cursorIndex {
			end = space
		}
		return (String(text[start ..< end]), text.distance(from: start, to: cursorIndex))
	}

	struct Token {
		enum Kind { case shaped, name, plain }
		var text: String
		var kind: Kind
		/// Character offsets in the excerpt.
		var offset: Int
		var end: Int
	}

	static var tokenPattern: Regex<Substring> { #/[@#\/]?[A-Za-z][A-Za-z0-9]*(?:['’._+\-][A-Za-z0-9]+)*/# }

	static func tokenize(_ text: String) -> [Token] {
		var tokens: [Token] = []
		var offset = 0
		var cursor = text.startIndex
		for match in text.matches(of: tokenPattern) {
			offset += text.distance(from: cursor, to: match.range.lowerBound)
			let length = text.distance(from: match.range.lowerBound, to: match.range.upperBound)
			defer {
				offset += length
				cursor = match.range.upperBound
			}
			var word = String(match.output)
			let before = match.range.lowerBound == text.startIndex ? nil : text[text.index(before: match.range.lowerBound)]
			let after = match.range.upperBound == text.endIndex ? nil : text[match.range.upperBound]
			if let first = word.first, "@#/".contains(first) {
				// "and/or" is two words; "/Users/me" is a path, not a slash command.
				if before.map({ !$0.isWhitespace && !"([\"'`".contains($0) }) ?? false { word.removeFirst() }
				else if first == "/", after == "/" { continue }
			}
			for suffix in ["'s", "’s"] where word.hasSuffix(suffix) && word.count > suffix.count + 1 {
				word.removeLast(suffix.count)
			}
			let kind = classify(word, startsSentence: startsSentence(text, at: match.range.lowerBound))
			tokens.append(Token(text: word, kind: kind, offset: offset, end: offset + word.count))
		}
		return tokens
	}

	static func classify(_ word: String, startsSentence: Bool) -> Token.Kind {
		let letters = word.filter(\.isLetter)
		let hasDigit = word.contains(where: \.isNumber)
		// One letter is enough next to digits when it's a capital: M5, H2O.
		let enoughLetters = letters.count >= 2 || (hasDigit && letters.contains(where: \.isUppercase))
		guard enoughLetters, !ignoredWords.contains(word.lowercased()) else { return .plain }
		if let first = word.first, "@#/".contains(first) { return .shaped }
		let hasJoiner = word.dropFirst().dropLast().contains(where: { "._+".contains($0) })
		let innerUpper = word.dropFirst().contains(where: \.isUppercase)
		let hasLower = word.contains(where: \.isLowercase)
		if hasDigit || hasJoiner { return .shaped }
		if innerUpper { return .shaped } // SwiftUI, macOS, TCA, Wi-Fi
		guard word.first?.isUppercase == true, hasLower else { return .plain }
		return startsSentence ? .plain : .name
	}

	/// True when only whitespace, quotes, brackets or list markers stand between `index` and the start of
	/// the text, a line break, or a sentence's end.
	static func startsSentence(_ text: String, at index: String.Index) -> Bool {
		var i = index
		while i > text.startIndex {
			i = text.index(before: i)
			let c = text[i]
			if c.isNewline || ".!?:;".contains(c) { return true }
			if c == " " || c == "\t" || "\"'“‘([*#>-•–—`".contains(c) { continue }
			// A numbered list marker ("1. Foo") ends in a period, handled above.
			return false
		}
		return true
	}
}

// MARK: - Terms the user fixed

/// Spellings the user corrected in text they sent: a word or short phrase that was pasted one way and sent
/// spelled differently but alike ("/slop" → "/unslop", "equitable" → "equatable", "github" → "GitHub").
/// Content edits ("phone" → "laptop") and reordering aren't spelling fixes and are skipped.
public enum CorrectionTerms {
	public static let maxTerms = 30
	/// Only the newest edited texts are read, so the cost stays flat as the log grows (it's kept forever).
	static let maxEdits = 200
	/// Long edits are compared only up to this many words each side.
	static let maxTokens = 1500

	/// A fix to a plain lowercase word ("equitable" → "equatable") looks just like a content edit ("makes" →
	/// "takes"), so it counts only once the user has made it twice. Fixes with capitals, digits or symbols
	/// count the first time.
	public static func extract(from edits: [SentEdit], limit: Int = maxTerms) -> [String] {
		let newestFirst = edits.reversed().filter(\.wasEdited).prefix(maxEdits).map { fixes(pasted: $0.pasted, sent: $0.sent) }
		var plainCounts: [String: Int] = [:]
		for terms in newestFirst {
			for term in Set(terms) where isPlain(term) { plainCounts[term, default: 0] += 1 }
		}
		var result: [String] = []
		var seen = Set<String>()
		for term in newestFirst.joined() where !isPlain(term) || plainCounts[term, default: 0] >= 2 {
			guard seen.insert(term.lowercased()).inserted else { continue }
			result.append(term)
			if result.count >= limit { break }
		}
		return result
	}

	static func isPlain(_ term: String) -> Bool {
		term.allSatisfy { $0.isLowercase && $0.isLetter }
	}

	/// The sent spellings of every replaced span (1–3 words each side) that looks like a spelling fix.
	static func fixes(pasted: String, sent: String) -> [String] {
		fixPairs(pasted: pasted, sent: sent).map(\.new)
	}

	/// Every replaced span (1–3 words each side) that looks like a spelling fix, as pasted and as sent.
	/// `keepGrammar` keeps fixes that only add or drop an ending ("can" → "can't"), which the vocabulary
	/// leaves out but the speech coach wants: it has a second engine to tell edits from mishearings.
	public static func fixPairs(pasted: String, sent: String, keepGrammar: Bool = false) -> [(old: String, new: String)] {
		let a = words(pasted), b = words(sent)
		var pairs: [(old: String, new: String)] = []
		for (old, new) in replacements(a, b) where (1 ... 3).contains(old.count) && (1 ... 3).contains(new.count) {
			let oldText = old.joined(separator: " "), newText = new.joined(separator: " ")
			guard oldText != newText, newText.count >= 3 else { continue }
			let oldKey = oldText.lowercased().filter { !$0.isWhitespace }
			let newKey = newText.lowercased().filter { !$0.isWhitespace }
			// Dropping a capital ("The" → "the") isn't a spelling worth keeping.
			if oldKey == newKey, newText == newText.lowercased() { continue }
			// Nor is grammar: "take" → "takes", "app" → "app's", "walked" → "walk".
			if !keepGrammar, oldKey != newKey, newText == newText.lowercased(), oldKey.hasPrefix(newKey) || newKey.hasPrefix(oldKey) {
				continue
			}
			guard similarity(oldKey, newKey) >= 0.6 else { continue }
			pairs.append((oldText, newText))
		}
		return pairs
	}

	static func words(_ text: String) -> [String] {
		Array(text.matches(of: ContextTerms.tokenPattern).map { String($0.output) }.prefix(maxTokens))
	}

	/// Spans that differ between `a` and `b`, between the words they share (longest common subsequence).
	static func replacements(_ a: [String], _ b: [String]) -> [([String], [String])] {
		let n = a.count, m = b.count
		guard n > 0, m > 0 else { return [] }
		var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
		for i in stride(from: n - 1, through: 0, by: -1) {
			for j in stride(from: m - 1, through: 0, by: -1) {
				lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
			}
		}
		var result: [([String], [String])] = []
		var i = 0, j = 0
		var old: [String] = [], new: [String] = []
		func flush() {
			if !old.isEmpty, !new.isEmpty { result.append((old, new)) }
			old.removeAll()
			new.removeAll()
		}
		while i < n || j < m {
			if i < n, j < m, a[i] == b[j] {
				flush()
				i += 1
				j += 1
			} else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
				new.append(b[j])
				j += 1
			} else {
				old.append(a[i])
				i += 1
			}
		}
		flush()
		return result
	}

	/// 1 − edit distance / longer length.
	static func similarity(_ a: String, _ b: String) -> Double {
		let x = Array(a), y = Array(b)
		guard !x.isEmpty, !y.isEmpty else { return x.isEmpty && y.isEmpty ? 1 : 0 }
		var previous = Array(0 ... y.count)
		for i in 1 ... x.count {
			var current = [i] + Array(repeating: 0, count: y.count)
			for j in 1 ... y.count {
				current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
			}
			previous = current
		}
		return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
	}
}
