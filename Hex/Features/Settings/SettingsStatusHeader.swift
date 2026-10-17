import AppKit
import ComposableArchitecture
import HexCore
import Sauce
import SwiftUI

/// The first row of Settings: the app, whether dictation is ready, and the Private mode switch.
struct SettingsStatusHeader: View {
	@Bindable var store: StoreOf<SettingsFeature>
	var permissionsMissing: Bool

	var body: some View {
		HStack(spacing: 14) {
			Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
				.resizable()
				.frame(width: 64, height: 64)
				.accessibilityHidden(true)

			VStack(alignment: .leading, spacing: 4) {
				Text("LegacyScribe")
					.font(.system(size: 19, weight: .semibold))
				HStack(spacing: 6) {
					Circle()
						.fill(permissionsMissing ? Color.orange : Color.green)
						.frame(width: 8, height: 8)
					Text(statusLine)
						.font(.system(size: 13))
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.minimumScaleFactor(0.85)
				}
				.accessibilityElement(children: .combine)
			}

			Spacer(minLength: 12)

			HStack(spacing: 8) {
				Image(systemName: store.hexSettings.privateMode ? "lock.fill" : "lock.open")
					.font(.system(size: 12))
					.foregroundStyle(.secondary)
				Text("Private mode")
					.font(.system(size: 13))
				Toggle(
					"Private mode",
					isOn: Binding(
						get: { store.hexSettings.privateMode },
						set: { store.send(.setPrivateMode($0)) }
					)
				)
				.labelsHidden()
			}
			.fixedSize()
			.help("Nothing leaves this Mac: only the on-device model rewrites (other AIs are skipped and the text is pasted as heard), and there are no downloads, update checks or connection checks. Also in the menu bar menu.")
		}
		.padding(.vertical, 4)
	}

	private var statusLine: String {
		if permissionsMissing { return "Needs permissions below" }
		return "Ready · Hold \(Self.hotkeyText(store.hexSettings.hotkey)) to dictate · \(store.hexSettings.dictationMode.displayName) mode"
	}

	/// "Right ⌥", "⌘⇧ A": a side shows only when it isn't "either".
	static func hotkeyText(_ hotkey: HotKey) -> String {
		var parts: [String] = []
		if hotkey.modifiers.isHyperkey {
			parts.append("✦")
		} else {
			for modifier in hotkey.modifiers.sorted {
				let side = modifier.side == .either ? "" : "\(modifier.side.displayName) "
				parts.append(side + modifier.stringValue)
			}
		}
		if let key = hotkey.key { parts.append(key.toString) }
		return parts.isEmpty ? "your shortcut" : parts.joined(separator: " ")
	}
}
