import Foundation
import NaturalLanguage

/// Fits a dictation to the text around the cursor before it's pasted: lowercase start in the middle of a
/// sentence, no closing period when the sentence carries on after the cursor, and spaces where words meet.
/// Engines write every dictation as a complete sentence, which reads wrong when it lands mid-sentence.
public enum InsertionAdjuster {
	/// - Parameters:
	///   - before: the field's text before the cursor.
	///   - after: the field's text after the cursor (after the selection, which the paste replaces).
	///   - keepCapitalized: spellings that keep their first capital (vocabulary, fixed spellings, nearby names).
	public static func adjust(_ text: String, before: String, after: String, keepCapitalized: [String] = []) -> String {
		guard !text.isEmpty, text.first?.isWhitespace == false, text.last?.isWhitespace == false else { return text }
		var output = text
		// A structured answer (Prompt mode's sections) isn't a sentence fragment; only spacing applies.
		let singleLine = !text.contains(where: \.isNewline)

		if singleLine, !startsSentence(before), !keepsCapital(text, keepCapitalized: keepCapitalized) {
			output = output.prefix(1).lowercased() + output.dropFirst()
		}
		if singleLine, continuesSentence(after), endsWithDroppablePeriod(output) {
			output.removeLast()
		}
		if let last = before.last, needsSpace(after: last), let first = output.first, !closesOrPunctuates(first) {
			output = " " + output
		}
		if let first = after.first, first.isLetter || first.isNumber {
			output += " "
		}
		return output
	}

	/// True when the text before the cursor ends a sentence: nothing, a newline, `.`/`!`/`?`/`:` (closing quotes
	/// and brackets skipped), or a list marker at the start of the line.
	static func startsSentence(_ before: String) -> Bool {
		let line = before.lastIndex(where: \.isNewline).map { before[before.index(after: $0)...] } ?? before[...]
		let trimmedLine = line.trimmingCharacters(in: .whitespaces)
		if trimmedLine.isEmpty || isListMarker(trimmedLine) { return true }
		guard let last = trimmedLine.last(where: { !closingMarks.contains($0) }) else { return true }
		return ".!?:…".contains(last)
	}

	static func isListMarker(_ line: String) -> Bool {
		if ["-", "*", "•", "–", ">"].contains(line) { return true }
		guard let marker = line.last, ".)".contains(marker) else { return false }
		let number = line.dropLast()
		return !number.isEmpty && number.count <= 3 && number.allSatisfy(\.isNumber)
	}

	/// True when the first word must stay capitalized: "I" and its contractions, acronyms, words with inner
	/// capitals, known spellings, names (Natural Language's name tagger), weekdays and months.
	static func keepsCapital(_ text: String, keepCapitalized: [String]) -> Bool {
		guard let first = text.first, first.isUppercase else { return true }
		let word = String(text.prefix(while: { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" || $0 == "-" }))
		let bare = word.split(whereSeparator: { $0 == "'" || $0 == "’" }).first.map(String.init) ?? word
		if bare == "I" { return true }
		if bare.dropFirst().contains(where: \.isUppercase) { return true }
		if alwaysCapitalized.contains(bare.lowercased()) { return true }
		for term in keepCapitalized where term.first?.isUppercase == true && text.hasPrefix(term) {
			let rest = text.dropFirst(term.count)
			if rest.first.map({ !$0.isLetter && !$0.isNumber }) ?? true { return true }
		}
		let tagger = NLTagger(tagSchemes: [.nameType])
		tagger.string = text
		let (tag, _) = tagger.tag(at: text.startIndex, unit: .word, scheme: .nameType)
		return tag == .personalName || tag == .placeName || tag == .organizationName
	}

	/// True when the text after the cursor carries the sentence on: a lowercase word, or punctuation that
	/// already ends or continues it.
	static func continuesSentence(_ after: String) -> Bool {
		guard let first = after.first(where: { $0 != " " && $0 != "\t" }) else { return false }
		return first.isLowercase || first.isNumber || ",;:.!?".contains(first)
	}

	/// A single closing period that isn't part of an ellipsis or an abbreviation like "etc." or "e.g.".
	static func endsWithDroppablePeriod(_ text: String) -> Bool {
		guard text.hasSuffix("."), !text.hasSuffix("..") else { return false }
		let lastWord = text.dropLast().split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
		return !lastWord.contains(".") && !abbreviations.contains(lastWord.lowercased())
	}

	static func needsSpace(after character: Character) -> Bool {
		character.isLetter || character.isNumber || ".,;:!?)]}”’…".contains(character)
	}

	static func closesOrPunctuates(_ character: Character) -> Bool {
		".,;:!?)]}”’…".contains(character)
	}

	static let closingMarks: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}"]

	static let abbreviations: Set<String> = ["etc", "vs", "mr", "mrs", "ms", "dr", "st", "inc", "ltd", "jr", "sr"]

	static let alwaysCapitalized: Set<String> = [
		"monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
		"january", "february", "april", "june", "july", "august", "september", "october", "november", "december",
	]
}
