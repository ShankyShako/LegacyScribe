import SwiftUI

/// A 24 pt rounded square in a system colour with a white SF Symbol: the icon beside a Settings or About row.
struct SettingsTile: View {
	var symbol: String
	var color: Color

	var body: some View {
		RoundedRectangle(cornerRadius: 6, style: .continuous)
			.fill(color)
			.frame(width: 24, height: 24)
			.overlay(
				Image(systemName: symbol)
					.font(.system(size: 12, weight: .semibold))
					.foregroundStyle(.white)
			)
			.accessibilityHidden(true)
	}
}

/// Puts a `SettingsTile` beside a `Label`'s title. The label's icon supplies the symbol:
/// `Label("Name", systemImage: "mic.fill").labelStyle(.tile(.red))`, or `Label { … } icon: { Image(systemName:) }`.
struct TileLabelStyle: LabelStyle {
	var color: Color

	func makeBody(configuration: Configuration) -> some View {
		HStack(alignment: .center, spacing: 10) {
			configuration.icon
				.font(.system(size: 12, weight: .semibold))
				.foregroundStyle(.white)
				.frame(width: 24, height: 24)
				.background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color))
				.accessibilityHidden(true)
			// A title built from several views (a toggle and its caption) stacks them, as the default style does.
			VStack(alignment: .leading, spacing: 2) {
				configuration.title
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}
}

extension LabelStyle where Self == TileLabelStyle {
	static func tile(_ color: Color) -> TileLabelStyle { TileLabelStyle(color: color) }
}

/// Gray tile colour that reads as a system "neutral" in both appearances.
extension Color {
	static let settingsTileGray = Color(nsColor: .systemGray)
}
