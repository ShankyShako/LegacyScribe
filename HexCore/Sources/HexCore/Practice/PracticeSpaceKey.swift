import Foundation

/// Space in a practice session. A press starts recording. Released after `holdThreshold` or more, it
/// was hold-to-speak and the release stops; released sooner, it was a tap and the next press stops.
/// Key repeats must be filtered out before they get here.
public struct PracticeSpaceKey: Equatable, Sendable {
	public static let holdThreshold: TimeInterval = 2

	public enum Command: Equatable, Sendable {
		case start
		case stop
		case none
	}

	/// When the press that started the current recording went down, until it's released.
	var pressedAt: Date?

	public init() {}

	public mutating func keyDown(isRecording: Bool, canStart: Bool, at date: Date) -> Command {
		if isRecording {
			pressedAt = nil
			return .stop
		}
		guard canStart else { return .none }
		pressedAt = date
		return .start
	}

	public mutating func keyUp(isRecording: Bool, at date: Date) -> Command {
		defer { pressedAt = nil }
		guard isRecording, let pressedAt, date.timeIntervalSince(pressedAt) >= Self.holdThreshold else { return .none }
		return .stop
	}
}
