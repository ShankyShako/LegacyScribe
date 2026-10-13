import Foundation

/// The talk key in Notes mode: a clean tap (the hotkey pressed and released with nothing else in between)
/// starts a session, the next one stops it. Used instead of `HotKeyProcessor` while Notes mode is picked and
/// no dictation is running, or while a notes session records, so a double-tap lock can't swallow the
/// stopping tap. Firing on release means typing with the talk key held never starts a session.
public struct NotesTapDetector: Sendable {
	public enum Output: Equatable, Sendable {
		case tapped
		/// Esc with no modifiers.
		case escape
	}

	public var hotkey: HotKey
	private var isDown = false
	private var isClean = false

	public init(hotkey: HotKey) {
		self.hotkey = hotkey
	}

	public mutating func process(_ event: KeyEvent) -> Output? {
		if event.key == .escape, event.modifiers.isEmpty {
			isDown = false
			isClean = false
			return .escape
		}
		let matches = Self.matches(event, hotkey: hotkey)
		if matches {
			if !isDown {
				isDown = true
				isClean = true
			}
			return nil
		}
		guard isDown else { return nil }
		if Self.isRelease(event, hotkey: hotkey) {
			isDown = false
			defer { isClean = false }
			return isClean ? .tapped : nil
		}
		// Another key or an extra modifier while the hotkey is down: not a tap.
		isClean = false
		return nil
	}

	/// True while the hotkey is held; the caller swallows a key hotkey's own key presses.
	public var isHeld: Bool { isDown }

	static func matches(_ event: KeyEvent, hotkey: HotKey) -> Bool {
		if let key = hotkey.key {
			return event.key == key && event.modifiers.matchesExactly(hotkey.modifiers)
		}
		return event.key == nil && event.modifiers.matchesExactly(hotkey.modifiers)
	}

	/// The hotkey let go: for a key hotkey, its key lifted; for a modifier-only one, a required modifier lifted.
	static func isRelease(_ event: KeyEvent, hotkey: HotKey) -> Bool {
		if hotkey.key != nil {
			return event.key == nil
		}
		return event.key == nil && !hotkey.modifiers.isSubset(of: event.modifiers)
	}
}
