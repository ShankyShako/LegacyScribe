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

	public var displayName: String {
		switch self {
		case .raw: "Raw"
		case .clean: "Clean"
		case .prompt: "Prompt"
		}
	}

	public var summary: String {
		switch self {
		case .raw: "Paste exactly what was recognized"
		case .clean: "Remove filler and fix grammar, keep your wording"
		case .prompt: "Restructure into a clear request for a coding assistant"
		}
	}
}

extension RewriteMode {
	static let shortcutModifiers: Modifiers = [.control, .option]
	static let shortcutKeys: [Key: RewriteMode] = [.one: .raw, .two: .clean, .three: .prompt]

	/// ⌃⌥1 / ⌃⌥2 / ⌃⌥3 switch to Raw / Clean / Prompt; either side's Control and Option work.
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
		}
		return "⌃⌥\(number)"
	}

	/// Shown next to the menu bar icon; nil for the default mode so the icon stays clean.
	public var menuBarBadge: String? {
		switch self {
		case .raw: "R"
		case .clean: nil
		case .prompt: "P"
		}
	}
}
