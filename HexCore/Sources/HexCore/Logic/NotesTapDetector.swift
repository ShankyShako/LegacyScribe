import Foundation

/// The talk key in Notes mode: a clean tap (the hotkey pressed and released within `tapWindow`, nothing else
/// in between) starts a session; while one records, any clean press stops it. A longer hold in Notes mode
/// is an ordinary dictation, so the caller feeds the same events to `HotKeyProcessor` as well. Kept apart
/// from the processor because after a double-tap lock it reports the stopping press as a release.
/// Firing on release means typing with the talk key held never starts a session.
public struct NotesTapDetector: Sendable {
	public enum Output: Equatable, Sendable {
		/// A clean press released within `tapWindow`.
		case tapped
		/// A clean press held longer: a dictation, unless a session is recording.
		case released
		/// Esc with no modifiers.
		case escape
	}

	/// The double-tap window: a press released sooner is a tap, not a dictation.
	public static let tapWindow: TimeInterval = HexCoreConstants.doubleTapWindow

	public var hotkey: HotKey
	private var isDown = false
	private var isClean = false
	private var pressedAt = Date.distantPast

	public init(hotkey: HotKey) {
		self.hotkey = hotkey
	}

	public mutating func process(_ event: KeyEvent, at now: Date = Date()) -> Output? {
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
				pressedAt = now
			}
			return nil
		}
		guard isDown else { return nil }
		if Self.isRelease(event, hotkey: hotkey) {
			isDown = false
			defer { isClean = false }
			guard isClean else { return nil }
			return now.timeIntervalSince(pressedAt) <= Self.tapWindow ? .tapped : .released
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
