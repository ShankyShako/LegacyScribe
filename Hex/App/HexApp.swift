import ComposableArchitecture
import HexCore
import Inject
import AppKit
import SwiftUI

@main
struct HexApp: App {
	static let appStore = Store(initialState: AppFeature.State()) {
		AppFeature()
	}

	@NSApplicationDelegateAdaptor(HexAppDelegate.self) var appDelegate

	init() {
		#if DEBUG
		if NotesHarness.isRequested { NotesHarness.runAndExit() }
		#endif
		// Before anything builds a URLSession, so Private mode reaches every one of them.
		NetworkPolicy.install()
		@Shared(.hexSettings) var hexSettings: HexSettings
		NetworkPolicy.setPrivate(hexSettings.privateMode)
	}
  
    var body: some Scene {
        MenuBarExtra {
            MenuBarCopyLastTranscriptButton()
            MenuBarLastLatencyView()
            MenuBarRewriteModePicker()
            MenuBarPrivateModeToggle()

            Button("Settings…") {
                appDelegate.presentSettingsView()
            }.keyboardShortcut(",")
            MenuBarUpdateButton()

			Divider()
			
			Button("Quit LegacyScribe") {
				NSApplication.shared.terminate(nil)
			}.keyboardShortcut("q")
		} label: {
			MenuBarIconLabel()
		}
		.commands {
			CommandGroup(after: .appInfo) {
				MenuBarUpdateButton()

				Button("Settings…") {
					appDelegate.presentSettingsView()
				}.keyboardShortcut(",")
			}

			CommandGroup(replacing: .help) {}
		}
	}
}
