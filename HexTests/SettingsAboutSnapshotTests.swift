import AppKit
import ComposableArchitecture
import HexCore
import SwiftUI
import XCTest

@testable import Hex

/// Renders the Settings and About tabs to `/tmp/settings-build/*.png` for a look; it checks only that they
/// draw. The store runs no effects (an empty reducer), so nothing touches the microphone, the network or disk.
@MainActor
final class SettingsAboutSnapshotTests: XCTestCase {
	private func makeStore() -> StoreOf<SettingsFeature> {
		var state = SettingsFeature.State()
		let model = CohereModel.fourBit.identifier
		state.$hexSettings.withLock {
			$0.selectedModel = model
			$0.hasCompletedModelBootstrap = true
			$0.rewriteMode = .clean
		}
		state.modelDownload.availableModels = [ModelInfo(name: model, isDownloaded: true)]
		state.defaultInputDeviceName = "MacBook Pro Microphone"
		state.liveCaptionAvailable = true
		return Store(initialState: state) {
			Reduce<SettingsFeature.State, SettingsFeature.Action> { _, _ in .none }
		}
	}

	func testAboutRenders() throws {
		try render(AboutView(store: makeStore()), height: 760, name: "about")
	}

	func testSettingsRenders() throws {
		try render(
			SettingsView(
				store: makeStore(),
				microphonePermission: .granted,
				accessibilityPermission: .granted,
				inputMonitoringPermission: .granted
			),
			height: 2600,
			name: "settings"
		)
	}

	func testSettingsWithMissingPermissionsRenders() throws {
		try render(
			SettingsView(
				store: makeStore(),
				microphonePermission: .granted,
				accessibilityPermission: .denied,
				inputMonitoringPermission: .notDetermined
			),
			height: 700,
			name: "settings-permissions"
		)
	}

	func testLiveCaptionSectionRenders() throws {
		let store = makeStore()
		store.$hexSettings.withLock {
			$0.liveCaptionEnabled = true
			$0.liveCaptionPlacement = .custom
		}
		try render(Form { LiveCaptionSectionView(store: store) }.formStyle(.grouped), height: 270, name: "live-caption-settings")
		store.$hexSettings.withLock { $0.liveCaptionPlacement = .underIndicator }
		try render(Form { LiveCaptionSectionView(store: store) }.formStyle(.grouped), height: 200, name: "live-caption-settings-under")
	}

	/// The caption at each placement, and placing mode, on a plain 1512 x 982 desktop.
	func testCaptionPlacementsRender() throws {
		VisibleScreen.shared.adopt(size: CGSize(width: 1512, height: 982), inset: EdgeInsets(top: 32, leading: 0, bottom: 80, trailing: 0))
		let spot = CaptionSpot(x: 0.78, y: 0.55)
		for (name, placement, placing) in [
			("caption-under", CaptionPlacement.underIndicator, false),
			("caption-bottom", .bottom, false),
			("caption-custom", .custom, false),
			("caption-placing", .custom, true),
		] {
			var state = TranscriptionFeature.State()
			state.$hexSettings.withLock {
				$0.liveCaptionPlacement = placement
				$0.liveCaptionSpot = spot
			}
			state.isRecording = !placing
			state.$isPlacingCaption.withLock { $0 = placing }
			state.caption = placing ? nil : CaptionText(
				words: "Can you move the poster deadline to Monday and ask the printer whether they take PDFs at forty-eight by".split(separator: " ").map(String.init),
				dimLast: true
			)
			let store = Store(initialState: state) {
				Reduce<TranscriptionFeature.State, TranscriptionFeature.Action> { _, _ in .none }
			}
			let window = TranscriptionView(store: store).padding().padding(.top).padding(.top)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
			try render(
				ZStack {
					Color(red: 0.36, green: 0.42, blue: 0.50)
					RoundedRectangle(cornerRadius: 12).fill(Color.white).frame(width: 900, height: 640).offset(y: 40)
					window
				},
				width: 1512,
				height: 982,
				name: name
			)
			state.$isPlacingCaption.withLock { $0 = false }
		}
	}

	/// Drawn by an NSHostingView in an offscreen window, which draws AppKit-backed controls properly.
	private func render(_ view: some View, width: CGFloat = 720, height: CGFloat, name: String) throws {
		let hosting = NSHostingView(rootView: view
			.frame(width: width, height: height)
			.environment(\.colorScheme, .light))
		hosting.appearance = NSAppearance(named: .aqua)
		hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
		let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
		window.appearance = NSAppearance(named: .aqua)
		window.contentView = hosting
		hosting.layoutSubtreeIfNeeded()
		// Let the Form lay its rows out and any .task settle before drawing.
		RunLoop.current.run(until: Date().addingTimeInterval(0.6))
		hosting.layoutSubtreeIfNeeded()
		let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
		hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
		let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
		try FileManager.default.createDirectory(atPath: "/tmp/settings-build", withIntermediateDirectories: true)
		try data.write(to: URL(fileURLWithPath: "/tmp/settings-build/\(name).png"))
	}
}
