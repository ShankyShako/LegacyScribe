import AppKit
import HexCore
import SwiftUI
import XCTest

@testable import Hex

/// Renders the speaker chips and the naming popover's form (option A) to `/tmp/speaker-naming-*.png` for a
/// look; it checks only that they render. The popover's window chrome is drawn here: a real NSPopover is its
/// own window.
/// Where the drawn popover arrow sits from the card's left edge.
private let popoverArrowInset: CGFloat = 28

@MainActor
final class NotesSpeakerNamingSnapshotTests: XCTestCase {
	private static let lines = [
		"Posters are A0 portrait, and the printing deadline is the ninth. Anything later hangs on the wall as a PDF.",
		"Can we bring a laptop to demo the app, or does everything have to be on the poster?",
		"A laptop is fine as long as it's on battery. There are only four sockets for the whole room.",
		"And please tell the judges what you built yourselves versus what you borrowed.",
	]

	private static func paragraphs(other: (label: String, recognised: Bool, saved: Bool)) -> [NotesSpeakerParagraph] {
		let speakers: [(Int, String, Bool, Bool, Bool)] = [
			(2, other.label, false, other.recognised, other.saved), (1, "You", true, false, false),
			(3, "Speaker 3", false, false, false), (2, other.label, false, other.recognised, other.saved),
		]
		return zip(speakers, lines).map { speaker, text in
			NotesSpeakerParagraph(
				speaker: speaker.0, label: speaker.1, isUser: speaker.2, text: text, overlapping: false,
				seconds: 340, recognised: speaker.3, voiceSaved: speaker.4
			)
		}
	}

	func testChipsAndNamingPopoverRender() throws {
		let before = Self.paragraphs(other: ("Speaker 2", false, false))
		let transcript = NotesSpeakerTranscript(paragraphs: before, onName: { _, _, _ in })
		let popover = NotesSpeakerNamingForm(paragraph: before[0], onSave: { _, _ in }, onCancel: {})
		try render(
			ZStack(alignment: .topLeading) {
				transcript
				PopoverChrome { popover }
					// Under the first chip, its arrow on the chip's centre.
					.offset(x: NotesSpeakerTranscript.chipWidth / 2 - popoverArrowInset, y: 24)
			}
			.frame(width: 640, height: 300, alignment: .topLeading),
			"before"
		)
		try render(NotesSpeakerTranscript(paragraphs: Self.paragraphs(other: ("Dr. Lee", false, true)), onName: { _, _, _ in }), "after")
		try render(NotesSpeakerTranscript(paragraphs: Self.paragraphs(other: ("Dr. Lee", true, false)), onName: { _, _, _ in }), "later")
		try render(
			NotesSpeakerNamingForm(paragraph: Self.paragraphs(other: ("Dr. Lee", true, false))[0], onSave: { _, _ in }, onCancel: {}),
			"rename-recognised"
		)
	}

	/// A macOS popover's look: rounded card, hairline, shadow, an arrow pointing up at `arrowInset`.
	private struct PopoverChrome<Content: View>: View {
		@ViewBuilder var content: Content

		var body: some View {
			VStack(alignment: .leading, spacing: 0) {
				Triangle()
					.fill(Color(nsColor: .windowBackgroundColor))
					.frame(width: 18, height: 9)
					.padding(.leading, popoverArrowInset - 9)
				content
					.background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
					.overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
			}
			.compositingGroup()
			.shadow(color: .black.opacity(0.2), radius: 10, y: 4)
		}
	}

	private struct Triangle: Shape {
		func path(in rect: CGRect) -> Path {
			Path { path in
				path.move(to: CGPoint(x: rect.midX, y: rect.minY))
				path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
				path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
				path.closeSubpath()
			}
		}
	}

	/// Drawn by an NSHostingView in an offscreen window rather than ImageRenderer, which draws the text field
	/// and checkbox (AppKit controls) as placeholders.
	private func render(_ view: some View, _ name: String) throws {
		let hosting = NSHostingView(rootView: view
			.fixedSize(horizontal: false, vertical: true)
			.frame(width: 640, alignment: .leading)
			.padding(20)
			.background(Color.white)
			.environment(\.colorScheme, .light))
		hosting.appearance = NSAppearance(named: .aqua)
		hosting.frame.size = hosting.fittingSize
		let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
		window.contentView = hosting
		hosting.layoutSubtreeIfNeeded()
		let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
		hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
		let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
		try data.write(to: URL(fileURLWithPath: "/tmp/speaker-naming-\(name).png"))
	}
}
