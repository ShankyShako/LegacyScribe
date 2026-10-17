import ComposableArchitecture
import HexCore
import SwiftUI

/// The live caption: whether it shows, where, and (for "where I put it") a button that puts a sample on screen to drag.
struct LiveCaptionSectionView: View {
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		let enabled = store.hexSettings.liveCaptionEnabled
		let placement = store.hexSettings.liveCaptionPlacement

		Section {
			Label {
				Toggle(
					"Show what you're saying",
					isOn: Binding(
						get: { store.hexSettings.liveCaptionEnabled },
						set: { store.send(.setLiveCaptionEnabled($0)) }
					)
				)
				Text("Your words appear as you speak, from Apple's on-device speech model. The newest word is dimmed until it settles.")
					.settingsCaption()
			} icon: {
				Image(systemName: "captions.bubble")
			}
			.labelStyle(.tile(.teal))

			Label {
				HStack {
					Text("Position")
					Spacer()
					Picker("Position", selection: Binding(
						get: { store.hexSettings.liveCaptionPlacement },
						set: { store.send(.setLiveCaptionPlacement($0)) }
					)) {
						ForEach(CaptionPlacement.allCases, id: \.self) { placement in
							Text(placement.displayName).tag(placement)
						}
					}
					.labelsHidden()
					.fixedSize()
				}
			} icon: {
				Image(systemName: "rectangle.bottomthird.inset.filled")
			}
			.labelStyle(.tile(.teal))
			.disabled(!enabled)

			if placement == .custom {
				Label {
					HStack {
						VStack(alignment: .leading, spacing: 2) {
							Text("Caption spot")
							Text("Shows a sample caption on screen to drag into place.")
								.settingsCaption()
						}
						Spacer()
						Button("Place caption…") { store.send(.setPlacingCaption(true)) }
					}
				} icon: {
					Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
				}
				.labelStyle(.tile(.teal))
				.disabled(!enabled)
			}
		} header: {
			Text("Live caption")
		}
	}
}
