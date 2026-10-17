import ComposableArchitecture
import HexCore
import SwiftUI

/// Points to the Notes tab, where the notes settings live beside the sessions they apply to.
struct NotesSectionView: View {
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section {
			Label {
				HStack {
					Text("The model that writes your notes, the export folder and the voices Notes recognises are set in the Notes tab.")
						.settingsCaption()
					Spacer()
					Button("Notes Settings…") { store.send(.openNotesSettings) }
				}
			} icon: {
				Image(systemName: RewriteMode.notes.systemImage)
			}
			.labelStyle(.tile(.yellow))
		} header: {
			Text("Notes")
		}
	}
}
