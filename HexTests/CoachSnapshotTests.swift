import AppKit
import ComposableArchitecture
import HexCore
import SwiftUI
import XCTest

@testable import Hex

/// Renders the Coach tab, the minute's result and the share card with made-up stats to PNGs
/// (`$TMPDIR/coach-*.png`) for a look; it checks only that they render.
@MainActor
final class CoachSnapshotTests: XCTestCase {
	func testTheScorecardRenders() throws {
		let start = Date(timeIntervalSince1970: 1_789_948_800) // Mon 21 Sep 2026
		var clips: [CoachClip] = []
		for day in stride(from: 0, to: 25, by: 1) {
			let week = day / 7
			clips.append(CoachClip(
				dictationID: UUID(), date: start.addingTimeInterval(Double(day) * 86400), mode: "clean", appName: "Slack",
				engine: "parakeet-tdt-0.6b-v3", words: 220, speakingSeconds: 90,
				fillers: ["um": 4 - week, "uh": 1], fillerOffsets: [0.4, 6], corrections: ["no": 1, "repeated": 1],
				sentencePauses: [0.7, 0.6], thoughtPauses: [0.6, 0.8],
				crutches: ["just": 3, "like": 1], hedges: ["i think": 2, "maybe": 1],
				sentenceLengths: [14, 18, 22, 45], runOns: day % 4 == 0 ? 1 : 0,
				moments: [CoachMoment(kind: .filler, label: "um", time: 2.4), CoachMoment(kind: .fluent, label: "", time: 5.1, seconds: 3.2),
				          CoachMoment(kind: .crutch, label: "just", time: 7.0), CoachMoment(kind: .hedge, label: "i think", time: 9.2)],
				misheard: day % 6 == 0 ? [CoachMisheard(said: "can't", heard: "can")] : []
			))
		}
		var state = CoachFeature.State()
		state.clips = clips
		state.minutes = [CoachMinute(date: start, topic: "t", engine: "p", words: 140, speakingSeconds: 55, fillers: ["um": 1], pitchRange: 6.2)]
		state.summary = CoachSummary(clips, now: start.addingTimeInterval(25 * 86400))
		state.pending = 41
		let store = Store(initialState: state) { CoachFeature() } withDependencies: { $0.coach = .testValue }

		try render(CoachView(store: store).content.frame(width: 640).background(Color(nsColor: .windowBackgroundColor)), "scorecard")
		try render(CoachShareCard(summary: state.summary, best: state.minutes.first), "share")
	}

	/// System colours resolve under the current drawing appearance, not SwiftUI's colour scheme, so both are set.
	private func render(_ view: some View, _ name: String) throws {
		var rendered: NSImage?
		NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
			let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
			renderer.scale = 2
			rendered = renderer.nsImage
		}
		let image = try XCTUnwrap(rendered)
		let data = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
		try data.write(to: URL(fileURLWithPath: "/tmp/coach-\(name).png"))
	}
}
