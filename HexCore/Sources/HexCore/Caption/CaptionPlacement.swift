import CoreGraphics
import Foundation

public enum CaptionPlacement: String, Codable, CaseIterable, Sendable {
	case underIndicator, bottom, custom

	public var displayName: String {
		switch self {
		case .underIndicator: "Under the indicator"
		case .bottom: "Bottom of the screen"
		case .custom: "Where I put it"
		}
	}
}

/// The caption's centre as fractions (0-1) of the screen's visible frame, top-left origin. Fractions, not points,
/// so the spot survives a resolution change and carries over to another screen.
public struct CaptionSpot: Codable, Equatable, Sendable {
	public var x: Double
	public var y: Double

	public init(x: Double, y: Double) {
		self.x = x
		self.y = y
	}
}

public enum CaptionLayout {
	public static let defaultSpot = CaptionSpot(x: 0.5, y: 0.85)
	static let bottomMargin: CGFloat = 24
	static let edgeMargin: CGFloat = 8

	/// The caption's centre inside `visible` (top-left origin, in the window's coordinates), or nil for
	/// `.underIndicator`, where the view stacks the caption under the indicator itself.
	/// `dockInset` is reserved for the caller; `visible` is already net of the Dock and menu bar.
	public static func center(
		placement: CaptionPlacement,
		spot: CaptionSpot?,
		visible: CGRect,
		caption: CGSize,
		dockInset: CGFloat = 0
	) -> CGPoint? {
		switch placement {
		case .underIndicator:
			return nil
		case .bottom:
			return bottomCenter(visible: visible, caption: caption)
		case .custom:
			guard let spot else { return bottomCenter(visible: visible, caption: caption) }
			let rawX = visible.minX + CGFloat(spot.x) * visible.width
			let rawY = visible.minY + CGFloat(spot.y) * visible.height
			return CGPoint(
				x: clamp(rawX, visible.minX + edgeMargin + caption.width / 2, visible.maxX - edgeMargin - caption.width / 2),
				y: clamp(rawY, visible.minY + edgeMargin + caption.height / 2, visible.maxY - edgeMargin - caption.height / 2)
			)
		}
	}

	private static func bottomCenter(visible: CGRect, caption: CGSize) -> CGPoint {
		CGPoint(x: visible.midX, y: visible.maxY - bottomMargin - caption.height / 2)
	}

	/// Clamps into `low...high`; if the range is empty (caption larger than the screen) the centre of the range wins.
	private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
		guard low <= high else { return (low + high) / 2 }
		return min(max(value, low), high)
	}
}
