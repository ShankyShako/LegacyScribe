import Foundation

/// "Legacy" said first turns one dictation into an instruction: "Legacy, make this shorter." edits the selection,
/// "Legacy, reply saying I'm in for Thursday." writes at the cursor.
///
/// The trigger is "legacy mode", or "legacy" followed by a pause, which the recognizer writes as punctuation
/// ("Legacy," "Legacy." "Legacy!"). "Legacy code is hard to change" has no pause and stays a dictation.
public enum SuperTrigger {
	/// How many times a selection without "legacy" shows the "say 'legacy' first" hint.
	public static let hintLimit = 3

	/// When the start of a recording is transcribed to spot "legacy" early, in seconds after key-down.
	public static let peekSeconds: [Double] = [1.0, 1.7, 2.5, 3.3]

	/// The spoken trigger: the app's name, or its nickname.
	public static let words: Set<String> = ["legacy", "lucy"]

	/// Words skipped before "legacy".
	static let fillers: Set<String> = ["um", "uh", "erm", "er"]

	/// The instruction after the trigger, trimmed; empty when "legacy" was all that was said. Nil when the
	/// dictation doesn't start with the trigger.
	public static func instruction(in transcript: String) -> String? {
		var rest = Substring(transcript)
		while true {
			rest = rest.drop { $0.isWhitespace || $0.isPunctuation }
			guard let word = firstWord(of: rest), fillers.contains(word.lowercased()) else { break }
			rest = rest.dropFirst(word.count)
		}
		guard let word = firstWord(of: rest) else { return nil }
		let lowered = word.lowercased()
		if lowered.hasSuffix("mode"), words.contains(String(lowered.dropLast(4))) {
			return remainder(after: rest.dropFirst(word.count))
		}
		guard words.contains(lowered) else { return nil }
		rest = rest.dropFirst(word.count)

		let afterSuper = rest.drop { $0.isWhitespace }
		let spacedDash = afterSuper.count < rest.count && afterSuper.first.map { "-–—".contains($0) } == true
		if let next = firstWord(of: afterSuper), next.lowercased() == "mode" {
			rest = afterSuper.dropFirst(next.count)
		} else if !spacedDash, !(rest.first.map(isPause) ?? true) {
			// "Legacy code is hard to change": no pause after the word.
			return nil
		}
		return remainder(after: rest)
	}

	static func remainder(after text: Substring) -> String {
		text.drop { $0.isWhitespace || $0.isPunctuation }.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// What a partial transcript of the first seconds says, for the indicator while recording. The final
	/// transcript still decides.
	public struct EarlyVerdict: Equatable, Sendable {
		/// Nil until there's something to go on ("um", or a bare "legacy" that may be "legacy code").
		public var isSuper: Bool?
		/// Later audio won't change the answer: the trigger was followed by an instruction, or two words
		/// were heard without it.
		public var isSettled: Bool
	}

	public static func earlyVerdict(_ partial: String) -> EarlyVerdict {
		let heard = partial.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }
			.map { $0.lowercased() }
			.filter { !fillers.contains($0) }
		guard let first = heard.first else { return EarlyVerdict(isSuper: nil, isSettled: false) }
		if let instruction = instruction(in: partial) {
			// A bare "legacy" with no pause after it yet may still turn out to be "legacy code".
			let barePause = heard.count == 1 && Self.words.contains(first) && !(partial.last.map(isPause) ?? false)
			return EarlyVerdict(isSuper: barePause ? nil : true, isSettled: !instruction.isEmpty)
		}
		return EarlyVerdict(isSuper: false, isSettled: heard.count >= 2 || !Self.words.contains(first))
	}

	/// Punctuation a recognizer writes for a pause. A hyphen counts only with a space before it, so
	/// "legacy-free" isn't a trigger.
	static func isPause(_ character: Character) -> Bool {
		",.!?:;…—–".contains(character)
	}

	static func firstWord(of text: Substring) -> Substring? {
		let word = text.prefix { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }
		return word.isEmpty ? nil : word
	}
}
