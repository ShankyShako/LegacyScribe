import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct SoundSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		let sliderBinding = Binding<Double>(
			get: { volumePercentage(for: store.hexSettings.soundEffectsVolume) },
			set: { store.send(.setSoundEffectsVolume(actualVolume(fromPercentage: $0))) }
		)

		return Section {
			Label {
				HStack(spacing: 10) {
					Text("Sound effects")
					Spacer(minLength: 12)
					Slider(value: sliderBinding, in: 0...1) {
						Text("Volume")
					}
					.labelsHidden()
					.frame(width: 110)
					.disabled(!store.hexSettings.soundEffectsEnabled)
					.help("Volume \(formattedVolume(for: store.hexSettings.soundEffectsVolume))")
					.accessibilityValue(formattedVolume(for: store.hexSettings.soundEffectsVolume))
					Toggle(
						"Sound effects",
						isOn: Binding(
							get: { store.hexSettings.soundEffectsEnabled },
							set: { store.send(.setSoundEffectsEnabled($0)) }
						)
					)
					.labelsHidden()
				}
			} icon: {
				Image(systemName: "speaker.wave.2.fill")
			}
			.labelStyle(.tile(.pink))
		} header: {
			Text("Sound")
		}
		.enableInjection()
	}
}

private func formattedVolume(for actualVolume: Double) -> String {
	let percent = volumePercentage(for: actualVolume)
	return "\(Int(round(percent * 100)))%"
}

private func volumePercentage(for actualVolume: Double) -> Double {
	guard HexSettings.baseSoundEffectsVolume > 0 else { return 0 }
	let ratio = actualVolume / HexSettings.baseSoundEffectsVolume
	return max(0, min(1, ratio))
}

private func actualVolume(fromPercentage percentage: Double) -> Double {
	let clampedPercentage = max(0, min(1, percentage))
	return clampedPercentage * HexSettings.baseSoundEffectsVolume
}
