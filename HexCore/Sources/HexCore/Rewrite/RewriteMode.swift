import Foundation

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
