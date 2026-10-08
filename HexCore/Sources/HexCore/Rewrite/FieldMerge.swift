import Foundation

/// Prompt mode's merge: when the focused field already holds text (an earlier prompt), the new dictation
/// is merged into it ("add cheesecake" becomes one more bullet in the existing list) and the merged text
/// replaces the field, instead of a second, separate prompt being pasted after it.
public enum FieldMerge {
	/// Longer fields aren't sent to the LLM: the round trip would be slow and the field is likely a document.
	public static let maxExistingCharacters = 6000

	/// Terminals expose their whole scrollback as the field's text, so there is nothing to merge into.
	public static let terminalBundleIDs: Set<String> = [
		"com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
		"net.kovidgoyal.kitty", "io.alacritty", "org.alacritty", "com.github.wez.wezterm",
	]

	/// The field text to merge into, or nil to paste normally.
	public static func existingText(_ fieldText: String?, bundleID: String?) -> String? {
		guard let fieldText, let bundleID, !terminalBundleIDs.contains(bundleID) else { return nil }
		let trimmed = fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed.count <= maxExistingCharacters else { return nil }
		return trimmed
	}

	static let instructions = """
	Merge: the text field already holds the text between <existing> tags, an earlier prompt the speaker is \
	adding to. Answer with the complete merged text: the existing text kept word for word and in order, with \
	the new dictation's points added where they belong. A new item for an existing list becomes one more \
	bullet in that list, in the same style; a new topic gets its own section or paragraph; a new question \
	joins the open questions. Rewrite only the new dictation, never the existing text. If the dictation \
	asks to change or remove something in the existing text, do that and nothing else.
	"""

	/// The user message for a merge.
	static func userMessage(existing: String, transcript: String) -> String {
		"<existing>\n\(existing)\n</existing>\n<dictation>\n\(transcript)\n</dictation>"
	}

	/// Nil when `merged` keeps the existing text; otherwise why the merge is rejected. Allows the model to
	/// edit a few lines (the dictation may ask for that) but not to drop or rewrite most of them. A field of
	/// one or two lines may be rewritten whole ("make it the signup bug, not login").
	public static func rejection(of merged: String, existing: String) -> String? {
		let lines = existing
			.components(separatedBy: .newlines)
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty }
		guard lines.count >= 3 else { return nil }
		let kept = lines.filter { merged.contains($0) }.count
		let allowedEdits = max(1, lines.count / 5)
		if kept < max(1, lines.count - allowedEdits) {
			return "merge kept \(kept) of \(lines.count) existing lines"
		}
		return nil
	}
}
