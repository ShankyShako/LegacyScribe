import Foundation
import Sauce

/// What happens to a transcript between speech-to-text and paste.
public enum RewriteMode: String, Codable, CaseIterable, Equatable, Sendable {
	/// Paste the transcript as recognized.
	case raw
	/// Remove fillers and false starts, fix grammar and punctuation, keep the speaker's voice.
	case clean
	/// Restructure the dictation into a direct request for an AI coding assistant.
	case prompt
	/// Not a rewrite: the talk key starts a hands-free notes session (up to 2 h) instead of a dictation,
	/// and a local model writes notes from it afterwards.
	case notes

	public var displayName: String {
		switch self {
		case .raw: "Raw"
		case .clean: "Clean"
		case .prompt: "Prompt"
		case .notes: "Notes"
		}
	}

	public var summary: String {
		switch self {
		case .raw: "Paste exactly what was recognized"
		case .clean: "Remove filler and fix grammar, keep your wording"
		case .prompt: "Restructure into a clear request for a coding assistant"
		case .notes: "Tap the talk key to ramble up to 2 hours, tap again for notes"
		}
	}
}

extension RewriteMode {
	static let shortcutModifiers: Modifiers = [.control, .option]
	static let shortcutKeys: [Key: RewriteMode] = [.one: .raw, .two: .clean, .three: .prompt, .four: .notes]

	/// ⌃⌥1 / ⌃⌥2 / ⌃⌥3 / ⌃⌥4 switch to Raw / Clean / Prompt / Notes; either side's Control and Option work.
	public static func forShortcut(key: Key?, modifiers: Modifiers) -> RewriteMode? {
		guard let key, let mode = shortcutKeys[key], modifiers.matchesExactly(shortcutModifiers) else { return nil }
		return mode
	}

	/// e.g. "⌃⌥2"
	public var shortcutDescription: String {
		let number = switch self {
		case .raw: 1
		case .clean: 2
		case .prompt: 3
		case .notes: 4
		}
		return "⌃⌥\(number)"
	}

	/// SF Symbol for the mode, used in the on-screen mode notice.
	public var systemImage: String {
		switch self {
		case .raw: "text.alignleft"
		case .clean: "sparkles"
		case .prompt: "curlybraces"
		case .notes: "note.text"
		}
	}

	/// Shown next to the menu bar icon; nil for the default mode so the icon stays clean.
	public var menuBarBadge: String? {
		switch self {
		case .raw: "R"
		case .clean: nil
		case .prompt: "P"
		case .notes: "N"
		}
	}
}

extension RewriteMode {
	/// Modes whose dictations go through the LLM rewrite; Raw pastes as recognized and Notes isn't a dictation.
	public var rewrites: Bool {
		self == .clean || self == .prompt
	}
}
