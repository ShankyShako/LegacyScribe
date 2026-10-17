import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct PermissionsSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	let microphonePermission: PermissionStatus
	let accessibilityPermission: PermissionStatus
	let inputMonitoringPermission: PermissionStatus

	var body: some View {
		Section {
			// Microphone
			permissionRow(
				title: "Microphone",
				icon: "mic.fill",
				color: .red,
				status: microphonePermission,
				action: { store.send(.requestMicrophone) }
			)

			// Accessibility + Keyboard
			permissionRow(
				title: "Accessibility",
				icon: "accessibility",
				color: .blue,
				status: combinedAccessibilityStatus,
				action: {
					store.send(.requestAccessibility)
					store.send(.requestInputMonitoring)
				}
			)

			if store.hotkeyPermissionState.inputMonitoring != .granted {
				Label {
					HStack {
						Text("Input Monitoring is required so Hex can listen for your hotkey.")
							.font(.callout)
							.foregroundStyle(.primary)
						Spacer(minLength: 12)
						Button {
							store.send(.requestInputMonitoring)
						} label: {
							Text("Open Input Monitoring Settings")
						}
						.buttonStyle(.borderedProminent)
						.controlSize(.small)
					}
				} icon: {
					Image(systemName: "exclamationmark.triangle.fill")
				}
				.labelStyle(.tile(.yellow))
			}
		} header: {
			Text("Permissions")
		}
		.enableInjection()
	}

	@ViewBuilder
	private func permissionRow(
		title: String,
		icon: String,
		color: Color,
		status: PermissionStatus,
		action: @escaping () -> Void
	) -> some View {
		Label {
			HStack {
				Text(title)
				Spacer()
				switch status {
				case .granted:
					Image(systemName: "checkmark.circle.fill")
						.foregroundStyle(.green)
						.font(.body)
				case .denied, .notDetermined:
					Button("Grant") {
						action()
					}
					.buttonStyle(.bordered)
					.controlSize(.small)
				}
			}
		} icon: {
			Image(systemName: icon)
		}
		.labelStyle(.tile(color))
	}

	private var combinedAccessibilityStatus: PermissionStatus {
		if accessibilityPermission == .granted && inputMonitoringPermission == .granted {
			return .granted
		}
		if accessibilityPermission == .denied || inputMonitoringPermission == .denied {
			return .denied
		}
		return .notDetermined
	}
}
