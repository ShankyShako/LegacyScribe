import HexCore
import SwiftUI

/// What the pill under the recording indicator says.
enum DictationNotice: Equatable {
  /// The rewrite mode changed (⌃⌥1–3, the menu bar or Settings).
  case modeChanged(RewriteMode)
  /// Every rewrite endpoint failed, so the transcript was pasted as recognized.
  case rewriteFellBack
  /// Recording in a mode other than Clean, so the user knows which output to expect.
  case recordingIn(RewriteMode)

  var systemImage: String {
    switch self {
    case let .modeChanged(mode), let .recordingIn(mode): mode.systemImage
    case .rewriteFellBack: "exclamationmark.triangle.fill"
    }
  }

  var title: String {
    switch self {
    case let .modeChanged(mode): mode.displayName
    case let .recordingIn(mode): mode.displayName
    case .rewriteFellBack: "Rewrite failed: pasted as recognized"
    }
  }

  var detail: String? {
    switch self {
    case let .modeChanged(mode): mode.shortcutDescription
    case .rewriteFellBack, .recordingIn: nil
    }
  }

  var tint: Color {
    switch self {
    case .rewriteFellBack: .orange
    case .modeChanged, .recordingIn: .white
    }
  }

  /// How long a one-off notice stays up; the recording tag stays while recording.
  var holdDuration: Duration? {
    switch self {
    case .modeChanged: .milliseconds(1100)
    case .rewriteFellBack: .milliseconds(2600)
    case .recordingIn: nil
    }
  }
}

/// The small pill under the indicator. It fades in (strong ease-out, 180 ms, a 0.96 → 1 scale from the
/// top) and fades out (200 ms). A notice that replaces a visible one swaps its text in place instead of
/// replaying the entrance, so pressing ⌃⌥1, ⌃⌥2, ⌃⌥3 in a row doesn't flicker.
struct DictationNoticeView: View {
  var notice: DictationNotice

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: notice.systemImage)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(notice.tint)
      Text(notice.title)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
      if let detail = notice.detail {
        Text(detail)
          .font(.system(size: 11, weight: .regular).monospacedDigit())
          .foregroundStyle(.white.opacity(0.55))
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Capsule().fill(Color.black.opacity(0.8)))
    .overlay(Capsule().strokeBorder(notice.tint.opacity(notice.tint == .white ? 0.12 : 0.5), lineWidth: 1))
    .fixedSize()
    .accessibilityElement(children: .combine)
  }

  static let entrance = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
  static let exit = Animation.easeOut(duration: 0.2)

  static func transition(reduceMotion: Bool) -> AnyTransition {
    reduceMotion
      ? .opacity
      : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)), removal: .opacity)
  }
}

#Preview("Notices") {
  VStack(spacing: 12) {
    DictationNoticeView(notice: .modeChanged(.prompt))
    DictationNoticeView(notice: .recordingIn(.raw))
    DictationNoticeView(notice: .rewriteFellBack)
  }
  .padding(40)
}
