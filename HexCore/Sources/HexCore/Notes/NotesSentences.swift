import Foundation

/// Sentence splitting for trims (DESIGN.md "Notes trimming"). Hand-written and deterministic, not
/// `NLTokenizer`: a trim stores sentence coordinates, and they must mean the same thing after an OS update.
public enum NotesSentences {
	/// A sentence ends at a run of `.` `?` `!` (optionally followed by a closing `"`, `'` or `)`) that is
	/// followed by whitespace; the remainder is the last sentence. Each is whitespace-trimmed, empties are
	/// dropped. "e.g." and "Dr." split too: a finer snap point, not a wrong trim.
	public static func split(_ text: String) -> [String] {
		var sentences: [String] = []
		let characters = Array(text)
		var start = 0
		var index = 0
		while index < characters.count {
			guard terminators.contains(characters[index]) else {
				index += 1
				continue
			}
			var end = index
			while end < characters.count, terminators.contains(characters[end]) { end += 1 }
			while end < characters.count, closers.contains(characters[end]) { end += 1 }
			if end < characters.count, characters[end].isWhitespace {
				sentences.append(String(characters[start ..< end]))
				start = end
			}
			index = max(end, index + 1)
		}
		if start < characters.count { sentences.append(String(characters[start...])) }
		return sentences
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
	}

	private static let terminators: Set<Character> = [".", "?", "!"]
	private static let closers: Set<Character> = ["\"", "'", ")"]
}
