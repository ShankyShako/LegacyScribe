import Foundation

/// A term the user's history suggests adding to the rewrite vocabulary.
public struct VocabularySuggestion: Codable, Equatable, Identifiable, Sendable {
	public var term: String
	/// How speech recognition wrote it, e.g. ["tail scale", "tailscale"].
	public var heardAs: [String]
	public var reason: String

	public var id: String { term.lowercased() }

	public init(term: String, heardAs: [String], reason: String) {
		self.term = term
		self.heardAs = heardAs
		self.reason = reason
	}
}

/// On demand ("check my history"): asks an LLM which names and jargon the recognizer keeps getting wrong,
/// from pairs of recognized text and the text that was finally used.
public enum VocabularySuggester {
	/// Recognized text and what it became (the rewrite, or what the user sent).
	public struct Pair: Equatable, Sendable {
		public var recognized: String
		public var final: String

		public init(recognized: String, final: String) {
			self.recognized = recognized
			self.final = final
		}
	}

	/// Keeps the request small enough for a fast model; newest pairs first.
	public static let maxPromptCharacters = 14_000

	/// Pairs worth looking at: sent edits first (the strongest signal), then rewritten history entries,
	/// skipping pairs where nothing changed.
	public static func pairs(history: [Transcript], sentEdits: [SentEdit]) -> [Pair] {
		let fromEdits = sentEdits.reversed().map { Pair(recognized: $0.recognized, final: $0.sent) }
		let fromHistory = history.compactMap { entry in
			entry.rawText.map { Pair(recognized: $0, final: entry.text) }
		}
		var budget = maxPromptCharacters
		var result: [Pair] = []
		for pair in fromEdits + fromHistory where normalized(pair.recognized) != normalized(pair.final) {
			let size = pair.recognized.count + pair.final.count + 40
			guard size <= budget else { continue }
			budget -= size
			result.append(pair)
		}
		return result
	}

	public static func messages(pairs: [Pair], vocabulary: [String]) -> [ChatMessage] {
		let known = vocabulary.isEmpty ? "none" : vocabulary.joined(separator: ", ")
		let system = """
		You review a person's dictation history to improve their speech recognition. Each <pair> holds what \
		speech recognition heard and the text that was finally used (cleaned up by an LLM or edited by the \
		person). Suggest a term only when it is a name, product, file, command or technical term (one to \
		three words) and either recognition spelled it differently from the used text ("tail scale" heard, \
		"Tailscale" used), or it appears in at least two pairs with a spelling that ordinary autocorrect \
		would get wrong (unusual capitals, joined words). Never suggest ordinary words, descriptions, \
		phrases, UI element descriptions, spoken commands like "slash handoff", or terms already in their \
		vocabulary (\(known)). Use the spelling from the used text, with its capitals.
		Answer with only a JSON array, best first, at most 12 items: \
		[{"term": "exact spelling", "heardAs": ["the exact words from heard"], "reason": "one short sentence"}]. \
		Answer [] if nothing qualifies; an empty answer is better than a weak one.
		"""
		let body = pairs.map { "<pair>\nheard: \($0.recognized)\nused: \($0.final)\n</pair>" }.joined(separator: "\n")
		return [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: body)]
	}

	/// Reads the model's JSON array, tolerating code fences and prose around it; drops terms already in
	/// the vocabulary, blanks and duplicates.
	public static func parse(_ answer: String, vocabulary: [String]) -> [VocabularySuggestion]? {
		guard let start = answer.firstIndex(of: "["), let end = answer.lastIndex(of: "]"), start < end,
		      let suggestions = try? JSONDecoder().decode(
		      	[Loose].self,
		      	from: Data(answer[start ... end].utf8)
		      )
		else { return nil }
		var seen = Set(vocabulary.map { $0.lowercased() })
		return suggestions.compactMap { loose in
			let term = loose.term.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { return nil }
			return VocabularySuggestion(term: term, heardAs: loose.heardAs ?? [], reason: loose.reason ?? "")
		}
	}

	private struct Loose: Decodable {
		var term: String
		var heardAs: [String]?
		var reason: String?
	}

	/// Ignores only sentence capitalization and end punctuation, so "hello" and "Hello." match but
	/// "tail scale" and "Tailscale" don't.
	static func normalized(_ text: String) -> String {
		var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		while let last = trimmed.last, last.isPunctuation { trimmed.removeLast() }
		guard let first = trimmed.first else { return "" }
		return first.lowercased() + trimmed.dropFirst()
	}
}
