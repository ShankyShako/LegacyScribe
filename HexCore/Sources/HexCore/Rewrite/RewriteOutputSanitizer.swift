import Foundation

/// Strips what chat models wrap around an answer so only the rewritten text gets pasted.
public enum RewriteOutputSanitizer {
	public static func sanitize(_ output: String) -> String {
		var text = output
		text = removingThinkBlocks(text)
		text = text
			.replacingOccurrences(of: "<dictation>", with: "")
			.replacingOccurrences(of: "</dictation>", with: "")
		text = text.trimmingCharacters(in: .whitespacesAndNewlines)
		text = unwrappingCodeFence(text)
		text = unwrappingQuotes(text)
		text = asciiPunctuation(text)
		return text
			.components(separatedBy: "\n")
			.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
			.joined(separator: "\n")
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Reasoning models served through some proxies inline their chain of thought as `<think>…</think>`.
	static func removingThinkBlocks(_ text: String) -> String {
		var result = text.replacingOccurrences(
			of: "<think>[\\s\\S]*?</think>",
			with: "",
			options: .regularExpression
		)
		// An unterminated block means the answer never started.
		if let open = result.range(of: "<think>") {
			result = String(result[..<open.lowerBound])
		}
		return result
	}

	static func unwrappingCodeFence(_ text: String) -> String {
		guard text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6 else { return text }
		var lines = text.components(separatedBy: "\n")
		guard lines.count >= 3 else { return text }
		lines.removeFirst()
		lines.removeLast()
		return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
	}

	static func unwrappingQuotes(_ text: String) -> String {
		let pairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}")]
		for (open, close) in pairs {
			guard text.count >= 2, text.first == open, text.last == close else { continue }
			let inner = text.dropFirst().dropLast()
			// Leave text alone when the quotes are part of it, e.g. `"A" and "B"`.
			if inner.contains(open) || inner.contains(close) { continue }
			return String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
		}
		return text
	}

	/// Dictation lands in terminals and code editors, where typographic punctuation breaks things.
	static func asciiPunctuation(_ text: String) -> String {
		let map: [Character: String] = [
			"\u{2010}": "-", "\u{2011}": "-", "\u{2012}": "-",
			"\u{2018}": "'", "\u{2019}": "'",
			"\u{201C}": "\"", "\u{201D}": "\"",
			"\u{00A0}": " ", "\u{202F}": " ",
		]
		return String(text.flatMap { map[$0] ?? String($0) })
	}
}
