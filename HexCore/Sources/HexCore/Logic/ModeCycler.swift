import Foundation

/// Key logic for the ⌃⌥ mode switcher, which works like ⌘-Tab: hold Control, press Option, and a bar of
/// modes appears with the next mode picked. Each further Option press picks the one after, as does keeping
/// Option held (the caller's timer sends `advance`). Releasing Control switches to the picked mode.
///
/// Control must go down first: Right Option is the dictation key, and a press that starts with it belongs
/// to the dictation hotkey. Any other key or modifier aborts without switching, so ⌃⌥1 and other apps'
/// ⌃⌥ shortcuts keep working. The cycler never swallows events.
///
/// While Option is already held (holding the talk key), each Control tap steps to the next mode at once
/// (`stepped`), so the mode can change mid-sentence. The caller applies it only while recording, since
/// Left Option + Control is otherwise an ordinary chord.
public struct ModeCycler: Sendable {
	public enum Output: Equatable, Sendable {
		/// Control then Option went down: show the bar (after a short delay) with `highlight` picked,
		/// and start auto-advancing while Option stays held.
		case began(highlight: RewriteMode)
		/// Option was pressed again: pick the next mode now and restart the auto-advance timer.
		case advanced(highlight: RewriteMode)
		/// Option was released with Control still held: stop auto-advancing, keep the bar.
		case optionReleased
		/// Control was released: switch to `mode` and hide the bar.
		case committed(RewriteMode)
		/// Another key or modifier, or Escape: hide the bar without switching.
		case aborted
		/// Control was tapped while Option was already held: switch to `mode` now.
		case stepped(RewriteMode)
	}

	enum Phase: Equatable, Sendable {
		case idle
		/// Control alone is held; Option would start a cycle.
		case controlHeld
		case cycling(highlight: RewriteMode, optionHeld: Bool)
		/// Option alone went down first (the talk key); `controlDown` while a Control tap is in progress.
		case optionFirst(controlDown: Bool)
		/// Ignore everything until every key is up.
		case waitingForRelease
	}

	/// The bar appears this long after Option goes down, so ⌃⌥-chords typed quickly never flash it.
	public static let revealDelay: Duration = .milliseconds(250)
	/// While Option stays held, the pick moves on this often.
	public static let autoAdvanceInterval: Duration = .milliseconds(700)

	private(set) var phase: Phase = .idle

	public init() {}

	/// The mode after `mode`, wrapping around.
	public static func next(after mode: RewriteMode) -> RewriteMode {
		let all = RewriteMode.allCases
		let index = all.firstIndex(of: mode) ?? 0
		return all[(index + 1) % all.count]
	}

	public var highlight: RewriteMode? {
		if case let .cycling(highlight, _) = phase { return highlight }
		return nil
	}

	/// The caller's timer tick: picks the next mode while Option is held; nil otherwise.
	public mutating func advance() -> RewriteMode? {
		guard case let .cycling(highlight, true) = phase else { return nil }
		let next = Self.next(after: highlight)
		phase = .cycling(highlight: next, optionHeld: true)
		return next
	}

	/// Feeds one key event. `currentMode` is the mode in effect, so the first pick is the one after it.
	public mutating func handle(_ event: KeyEvent, currentMode: RewriteMode) -> Output? {
		let kinds = Set(event.modifiers.kinds)
		let allUp = event.key == nil && kinds.isEmpty

		switch phase {
		case .idle:
			if event.key == nil, kinds == [.control] { phase = .controlHeld }
			else if event.key == nil, kinds == [.option] { phase = .optionFirst(controlDown: false) }
			else if !allUp { phase = .waitingForRelease }
			return nil

		case let .optionFirst(controlDown):
			if allUp { phase = .idle; return nil }
			if event.key != nil || !kinds.isSubset(of: [.control, .option]) || !kinds.contains(.option) {
				phase = .waitingForRelease
				return nil
			}
			let controlNow = kinds.contains(.control)
			phase = .optionFirst(controlDown: controlNow)
			if controlDown, !controlNow {
				return .stepped(Self.next(after: currentMode))
			}
			return nil

		case .controlHeld:
			if allUp { phase = .idle; return nil }
			if event.key == nil, kinds == [.control] { return nil }
			if event.key == nil, kinds == [.control, .option] {
				let highlight = Self.next(after: currentMode)
				phase = .cycling(highlight: highlight, optionHeld: true)
				return .began(highlight: highlight)
			}
			phase = .waitingForRelease
			return nil

		case let .cycling(highlight, optionHeld):
			if event.key != nil || !kinds.isSubset(of: [.control, .option]) {
				phase = allUp ? .idle : .waitingForRelease
				return .aborted
			}
			if !kinds.contains(.control) {
				phase = kinds.isEmpty ? .idle : .waitingForRelease
				return .committed(highlight)
			}
			let optionDown = kinds.contains(.option)
			if optionDown, !optionHeld {
				let next = Self.next(after: highlight)
				phase = .cycling(highlight: next, optionHeld: true)
				return .advanced(highlight: next)
			}
			if !optionDown, optionHeld {
				phase = .cycling(highlight: highlight, optionHeld: false)
				return .optionReleased
			}
			return nil

		case .waitingForRelease:
			if allUp { phase = .idle }
			return nil
		}
	}
}
