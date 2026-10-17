import CoreGraphics
import Foundation
import Testing
@testable import HexCore

struct CaptionLayoutTests {
	private let visible = CGRect(x: 0, y: 0, width: 1512, height: 982)
	private let caption = CGSize(width: 364, height: 44)

	@Test
	func underIndicatorIsLeftToTheView() {
		#expect(CaptionLayout.center(placement: .underIndicator, spot: nil, visible: visible, caption: caption) == nil)
	}

	@Test
	func bottomIsCentredWithItsEdge24PointsAboveTheBottom() throws {
		let point = try #require(CaptionLayout.center(placement: .bottom, spot: nil, visible: visible, caption: caption))
		#expect(point.x == 756)
		#expect(point.y + caption.height / 2 == visible.maxY - 24)
	}

	@Test
	func aCustomSpotMapsFractionsIntoTheVisibleFrame() throws {
		let origin = CGRect(x: 100, y: 40, width: 1000, height: 800)
		let point = try #require(CaptionLayout.center(placement: .custom, spot: CaptionSpot(x: 0.5, y: 0.5), visible: origin, caption: caption))
		#expect(point == CGPoint(x: 600, y: 440))
	}

	@Test
	func aSpotNearTheCornerIsClampedInside() throws {
		let point = try #require(CaptionLayout.center(placement: .custom, spot: CaptionSpot(x: 0.95, y: 0.99), visible: visible, caption: caption))
		#expect(point.x + caption.width / 2 == visible.maxX - 8)
		#expect(point.y + caption.height / 2 == visible.maxY - 8)
		let low = try #require(CaptionLayout.center(placement: .custom, spot: CaptionSpot(x: 0, y: 0), visible: visible, caption: caption))
		#expect(low.x - caption.width / 2 == 8)
		#expect(low.y - caption.height / 2 == 8)
	}

	@Test
	func aCustomPlacementWithoutASpotEqualsBottom() {
		let custom = CaptionLayout.center(placement: .custom, spot: nil, visible: visible, caption: caption)
		let bottom = CaptionLayout.center(placement: .bottom, spot: nil, visible: visible, caption: caption)
		#expect(custom == bottom)
		#expect(custom != nil)
	}

	@Test
	func theDefaultSpotIsLowCentre() {
		#expect(CaptionLayout.defaultSpot == CaptionSpot(x: 0.5, y: 0.85))
	}

	@Test
	func settingsSavedBeforeTheCaptionParseWithItsDefaults() throws {
		let decoded = try JSONDecoder().decode(HexSettings.self, from: Data("{}".utf8))
		#expect(decoded.liveCaptionEnabled)
		#expect(decoded.liveCaptionPlacement == .underIndicator)
		#expect(decoded.liveCaptionSpot == nil)
	}

	@Test
	func captionSettingsRoundTrip() throws {
		var settings = HexSettings()
		settings.liveCaptionEnabled = false
		settings.liveCaptionPlacement = .custom
		settings.liveCaptionSpot = CaptionSpot(x: 0.3, y: 0.7)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: JSONEncoder().encode(settings))
		#expect(decoded.liveCaptionEnabled == false)
		#expect(decoded.liveCaptionPlacement == .custom)
		#expect(decoded.liveCaptionSpot == CaptionSpot(x: 0.3, y: 0.7))
	}
}
