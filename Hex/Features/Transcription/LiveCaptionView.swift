import ComposableArchitecture
import HexCore
import SwiftUI

extension SharedReaderKey
  where Self == InMemoryKey<Bool>.Default
{
  /// True while Settings has the sample caption on screen for the user to drag (`CaptionPlacingView`).
  static var isPlacingCaption: Self {
    Self[.inMemory("isPlacingCaption"), default: false]
  }
}

/// The live caption under the indicator: the same black pill as `DictationNoticeView`, the newest words at the
/// end, and only the last word dimmed while it is still volatile (option A of the mock-ups, one word instead of two).
struct LiveCaptionView: View {
  var caption: CaptionText
  /// The dashed accent outline of placing mode.
  var outlined = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let words = caption.words
    let head = (caption.dimLast ? Array(words.dropLast()) : words).joined(separator: " ")
    let tail = caption.dimLast ? (words.last ?? "") : ""
    let line = (
      Text(head).foregroundColor(.white)
        + Text(head.isEmpty || tail.isEmpty ? "" : " ")
        + Text(tail).foregroundColor(.white.opacity(0.55))
    ).font(.system(size: 13, weight: .medium))
    ViewThatFits(in: .horizontal) {
      line.lineLimit(1).fixedSize()
      line.lineLimit(2).truncationMode(.head)
        .frame(width: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    // A short caption hugs its words; a longer one wraps at 340 (the window offers far more than that).
    .frame(maxWidth: 340)
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.8)))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    .overlay {
      if outlined {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
          .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
          .padding(-4)
      }
    }
    .contentTransition(.opacity)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: tail)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(caption.text)
  }
}

/// Placing mode: a sample caption with a dashed accent outline and a small black bar, "Drag to place · Reset · Done".
/// The bar sits below the caption, or above it in the lower part of the screen so it stays visible.
struct CaptionPlacingView: View {
  var barAbove: Bool
  var onReset: () -> Void
  var onDone: () -> Void

  static let barHeight: CGFloat = 28
  static let barGap: CGFloat = 12
  static let sample = CaptionText(
    words: "Your words will appear here as you speak".split(separator: " ").map(String.init),
    dimLast: true
  )

  var body: some View {
    VStack(spacing: Self.barGap) {
      if barAbove { bar }
      LiveCaptionView(caption: Self.sample, outlined: true)
      if !barAbove { bar }
    }
  }

  /// Drawn like the Undo pill's button: a plain-styled capsule reads the same in an active or inactive window.
  private func barButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(filled ? Color.black : Color.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(filled ? Color.white : Color.white.opacity(0.18)))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }

  private var bar: some View {
    HStack(spacing: 8) {
      Text("Drag to place")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
      barButton("Reset", filled: false, action: onReset)
      barButton("Done", filled: true, action: onDone)
    }
    .padding(.horizontal, 10)
    .frame(height: Self.barHeight)
    .background(Capsule().fill(Color.black.opacity(0.8)))
  }
}

#Preview("Caption") {
  VStack(spacing: 12) {
    LiveCaptionView(caption: CaptionText(words: ["Can", "you", "move", "the", "post"], dimLast: true))
    LiveCaptionView(caption: CaptionText(words: "Could you check if the meeting is still scheduled for tomorrow at two PM and let me know".split(separator: " ").map(String.init), dimLast: true))
  }
  .padding(40)
}
