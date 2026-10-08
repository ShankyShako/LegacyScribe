import HexCore
import SwiftUI

/// The ⌃⌥ switcher's state in `TranscriptionFeature`: the mode that releasing Control will pick.
struct ModeCyclerBar: Equatable {
  var highlight: RewriteMode
  /// False for the first `ModeCycler.revealDelay`, so quickly typed ⌃⌥ chords don't flash the bar.
  var isVisible: Bool
}

/// Every mode in a row with the pick highlighted, shown while Control is held. The highlight slides to
/// the next mode (150 ms strong ease-out) so the eye can follow it; with Reduce Motion it jumps.
struct ModeCyclerBarView: View {
  var highlight: RewriteMode
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var namespace

  var body: some View {
    HStack(spacing: 2) {
      ForEach(RewriteMode.allCases, id: \.self) { mode in
        let isPicked = mode == highlight
        HStack(spacing: 5) {
          Image(systemName: mode.systemImage)
            .font(.system(size: 11, weight: .semibold))
          Text(mode.displayName)
            .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.white.opacity(isPicked ? 1 : 0.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
          if isPicked {
            Capsule()
              .fill(Color.white.opacity(0.18))
              .matchedGeometryEffect(id: "pick", in: namespace)
          }
        }
      }
    }
    .padding(3)
    .background(Capsule().fill(Color.black.opacity(0.8)))
    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    .animation(reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.15), value: highlight)
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Mode: \(highlight.displayName)")
  }
}

#Preview("Mode switcher") {
  VStack(spacing: 12) {
    ModeCyclerBarView(highlight: .raw)
    ModeCyclerBarView(highlight: .prompt)
  }
  .padding(40)
}
