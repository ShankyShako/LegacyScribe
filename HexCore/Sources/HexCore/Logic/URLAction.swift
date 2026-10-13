import Foundation

/// What a `legacyscribe://` (Release) or `legacyscribe-debug://` (Debug) URL asks for, so Shortcuts, Raycast,
/// Stream Deck or a script can drive dictation. The scheme isn't checked: macOS only hands the app its own.
public enum URLAction: Equatable, Sendable {
	case start
	case stop
	case toggle
	case cancel
	case mode(RewriteMode)
	case notesStart
	case notesStop

	/// `start`, `stop`, `toggle`, `cancel`, `mode/<raw|clean|prompt|notes>`, `notes/start`, `notes/stop`;
	/// case-insensitive, a trailing slash allowed.
	public init?(url: URL) {
		let parts = ([url.host(percentEncoded: false)] + url.pathComponents)
			.compactMap { $0?.lowercased() }
			.filter { !$0.isEmpty && $0 != "/" }
		switch parts {
		case ["start"]: self = .start
		case ["stop"]: self = .stop
		case ["toggle"]: self = .toggle
		case ["cancel"]: self = .cancel
		case ["notes", "start"]: self = .notesStart
		case ["notes", "stop"]: self = .notesStop
		case let parts where parts.count == 2 && parts[0] == "mode":
			guard let mode = RewriteMode(rawValue: parts[1]) else { return nil }
			self = .mode(mode)
		default: return nil
		}
	}

	/// Any web page can open a custom URL (the browser asks first), so actions that can turn the microphone
	/// on only run with `HexSettings.urlActionsEnabled`. Stopping, cancelling and switching modes always work.
	public var canStartRecording: Bool {
		switch self {
		case .start, .toggle, .notesStart: true
		case .stop, .cancel, .mode, .notesStop: false
		}
	}
}
