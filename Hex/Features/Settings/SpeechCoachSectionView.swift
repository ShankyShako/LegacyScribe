import ComposableArchitecture
import HexCore
import SwiftUI

/// The last section of Settings: the Speech Coach is off until turned on here (P3.6 D6).
struct SpeechCoachSectionView: View {
	@Bindable var store: StoreOf<SettingsFeature>
	@State private var confirmingDelete = false

	var body: some View {
		Section {
			Label {
				Toggle("Speech Coach", isOn: Binding(
					get: { store.hexSettings.speechCoachEnabled },
					set: { store.send(.setSpeechCoachEnabled($0)) }
				))
				Text("Shows how you speak: fillers, crutch words, pace and pauses, from your History recordings. Everything is worked out on this Mac.")
					.settingsCaption()
			} icon: {
				Image(systemName: "chart.line.downtrend.xyaxis")
			}

			if store.hexSettings.speechCoachEnabled {
				Label {
					Toggle("I stutter", isOn: Binding(
						get: { store.hexSettings.coachStutterFriendly },
						set: { store.send(.setCoachStutterFriendly($0)) }
					))
					Text("Repeated words and pauses inside sentences aren't counted against you, and pace and pause tips are left out.")
						.settingsCaption()
				} icon: {
					Image(systemName: "hand.raised")
				}

				HStack {
					Button("Open Speech Coach") { store.send(.openSpeechCoach) }
					Spacer()
					Button("Turn off and delete coach data", role: .destructive) { confirmingDelete = true }
				}
			}
		} header: {
			Text("Speech Coach")
		}
		.confirmationDialog("Delete the Speech Coach's data?", isPresented: $confirmingDelete) {
			Button("Turn Off and Delete", role: .destructive) { store.send(.deleteCoachData) }
		} message: {
			Text("This deletes the coach's stats and your filler-free minute scores, and turns the coach off. Your History and recordings stay.")
		}
	}
}
