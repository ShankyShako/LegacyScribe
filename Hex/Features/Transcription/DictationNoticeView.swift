import HexCore
import SwiftUI

/// What the pill under the recording indicator says.
enum DictationNotice: Equatable {
  /// The mode changed (⌃⌥1–4, the menu bar or Settings).
  case modeChanged(RewriteMode)
  /// Every rewrite endpoint failed, so the transcript was pasted as recognized.
  case rewriteFellBack
  /// Speech-to-text failed; the recording is in History with Retry.
  case dictationKept
  /// Recording in a mode other than Clean, so the user knows which output to expect.
  case recordingIn(RewriteMode)
  /// Recording with Private mode on: nothing will leave the Mac.
  case recordingPrivate(RewriteMode)
  /// A notes session is recording; the pill counts up from its start.
  case notesRecording(since: Date)
  /// Five minutes before a notes session's 2-hour cap.
  case notesEnding
  /// The session stopped; its transcript and notes are finished in the background.
  case notesSaved
  /// The session stopped itself after `NotesSilenceWatch.limit` without speech (it was left running).
  case notesStoppedSilent
  /// A notes session couldn't start (no Cohere, no microphone) or capture had a problem.
  case notesProblem(String)
  /// This dictation is a Legacy instruction (it started with "legacy"); stays up until it's done.
  case superOn
  /// Legacy changed nothing; the dictation was copied. The message says why.
  case superFailed(String)
  /// Text was selected at key-down without "legacy" (shown `SuperTrigger.hintLimit` times).
  case superHint

  var systemImage: String {
    switch self {
    case let .modeChanged(mode), let .recordingIn(mode): mode.systemImage
    case .recordingPrivate: "lock.fill"
    case .notesRecording: RewriteMode.notes.systemImage
    case .notesEnding: "clock"
    case .notesSaved: "checkmark.circle.fill"
    case .notesStoppedSilent: "waveform.slash"
    case .rewriteFellBack, .dictationKept, .notesProblem, .superFailed: "exclamationmark.triangle.fill"
    case .superOn, .superHint: "sparkle"
    }
  }

  var title: String {
    switch self {
    case let .modeChanged(mode): mode.displayName
    case let .recordingIn(mode): mode.displayName
    case let .recordingPrivate(mode): mode == .clean ? "Private" : "Private · \(mode.displayName)"
    case .rewriteFellBack: "Rewrite failed: pasted as recognized"
    case .dictationKept: "Transcription failed: kept in History"
    case .notesRecording: "Notes"
    case .notesEnding: "Notes stop in 5 min"
    case .notesSaved: "Saved: writing notes"
    case .notesStoppedSilent: "No speech for \(Int(NotesSilenceWatch.limit / 60)) min: notes stopped"
    case let .notesProblem(message): message
    case .superOn: "Legacy"
    case let .superFailed(message): message
    case .superHint: "Say \u{201C}legacy\u{201D} first to edit this"
    }
  }

  var detail: String? {
    switch self {
    case let .modeChanged(mode): mode.shortcutDescription
    case .rewriteFellBack, .dictationKept, .recordingIn, .recordingPrivate, .notesRecording, .notesEnding, .notesSaved, .notesStoppedSilent, .notesProblem, .superOn, .superFailed, .superHint: nil
    }
  }

  /// Counts up after the title.
  var timerStart: Date? {
    if case let .notesRecording(since) = self { since } else { nil }
  }

  var tint: Color {
    switch self {
    case .rewriteFellBack, .dictationKept, .notesProblem, .superFailed: .orange
    case .modeChanged, .recordingIn, .recordingPrivate, .notesRecording, .notesEnding, .notesSaved, .notesStoppedSilent, .superOn, .superHint: .white
    }
  }

  /// How long a one-off notice stays up; the recording tags stay while recording.
  var holdDuration: Duration? {
    switch self {
    case .modeChanged: .milliseconds(1100)
    case .rewriteFellBack, .notesSaved, .superHint: .milliseconds(2600)
    case .dictationKept, .notesEnding, .notesStoppedSilent, .notesProblem, .superFailed: .seconds(4)
    case .recordingIn, .recordingPrivate, .notesRecording, .superOn: nil
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
      if let start = notice.timerStart {
        Text(start, style: .timer)
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
    DictationNoticeView(notice: .notesRecording(since: .now.addingTimeInterval(-754)))
    DictationNoticeView(notice: .notesProblem("Notes needs Cohere Transcribe: download it in Settings > Models"))
  }
  .padding(40)
}
