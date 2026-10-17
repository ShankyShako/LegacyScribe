import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct SettingsView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	let microphonePermission: PermissionStatus
	let accessibilityPermission: PermissionStatus
	let inputMonitoringPermission: PermissionStatus
  
	var body: some View {
		Form {
			let permissionsMissing = microphonePermission != .granted
				|| accessibilityPermission != .granted
				|| inputMonitoringPermission != .granted

			Section {
				SettingsStatusHeader(store: store, permissionsMissing: permissionsMissing)
			}

			if permissionsMissing {
				PermissionsSectionView(
					store: store,
					microphonePermission: microphonePermission,
					accessibilityPermission: accessibilityPermission,
					inputMonitoringPermission: inputMonitoringPermission
				)
			}

			ModelSectionView(store: store, shouldFlash: store.shouldFlashModelSection)
			// Only WhisperKit models take a language; Parakeet detects it and Cohere is English-only here.
			if ParakeetModel(rawValue: store.hexSettings.selectedModel) == nil,
			   CohereModel(rawValue: store.hexSettings.selectedModel) == nil {
				LanguageSectionView(store: store)
			}

			HotKeySectionView(store: store)
          
			if microphonePermission == .granted {
				MicrophoneSelectionSectionView(store: store)
			}

			SoundSectionView(store: store)
			if store.liveCaptionAvailable {
				LiveCaptionSectionView(store: store)
			}
			GeneralSectionView(store: store)
			HistorySectionView(store: store)
			NotesSectionView(store: store)
			SpeechCoachSectionView(store: store)
		}
		.formStyle(.grouped)
		.task {
			await store.send(.task).finish()
		}
		// Placing mode ends with the Settings window.
		.onDisappear { store.send(.setPlacingCaption(false)) }
		.enableInjection()
	}
}

// MARK: - Shared Styles

extension Text {
	/// Applies caption font with secondary color, commonly used for helper/description text in settings.
	func settingsCaption() -> some View {
		self.font(.caption).foregroundStyle(.secondary)
	}
}
