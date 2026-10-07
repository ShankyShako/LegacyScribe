import ComposableArchitecture
import Inject
import AppKit
import SwiftUI

@main
struct HexApp: App {
	static let appStore = Store(initialState: AppFeature.State()) {
		AppFeature()
	}

	@NSApplicationDelegateAdaptor(HexAppDelegate.self) var appDelegate
  
    var body: some Scene {
        MenuBarExtra {
            MenuBarCopyLastTranscriptButton()
            MenuBarLastLatencyView()
            MenuBarRewriteModePicker()

            Button("Settings…") {
                appDelegate.presentSettingsView()
            }.keyboardShortcut(",")

			Divider()
			
			Button("Quit LegacyScribe") {
				NSApplication.shared.terminate(nil)
			}.keyboardShortcut("q")
		} label: {
			MenuBarIconLabel()
		}
		.commands {
			CommandGroup(after: .appInfo) {
				Button("Settings…") {
					appDelegate.presentSettingsView()
				}.keyboardShortcut(",")
			}

			CommandGroup(replacing: .help) {}
		}
	}
}
