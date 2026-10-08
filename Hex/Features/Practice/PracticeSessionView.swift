import ComposableArchitecture
import HexCore
import SwiftUI

/// One line at a time: Space records, Space again saves and moves on. Every saved line is kept, so
/// "Done for now" (or Escape) never loses anything.
struct PracticeSessionView: View {
	@Bindable var store: StoreOf<PracticeFeature>

	var body: some View {
		let script = PracticeScript.bundled
		VStack(alignment: .leading, spacing: 18) {
			if let session = store.session {
				header(session: session, script: script)
				if let line = session.line {
					Text(line.text)
						.font(.system(size: 26, weight: .medium))
						.lineSpacing(4)
						.frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
						.textSelection(.enabled)
					status(session: session)
				} else {
					Text("That's every line. Thank you!")
						.font(.title2)
						.frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
				}
				if let last = session.lastRecording {
					LastLineView(recording: last) { store.send(.redoLast) }
				}
				if let error = session.error {
					Text(error).font(.callout).foregroundStyle(.red)
				}
				controls(session: session)
			}
		}
		.padding(24)
		.frame(width: 640)
	}

	private func header(session: PracticeSession, script: PracticeScript) -> some View {
		let done = store.practiceLog.recordings.count
		return VStack(alignment: .leading, spacing: 6) {
			HStack {
				Text(session.line?.stage.title ?? "Done")
					.font(.headline)
				Spacer()
				Text("\(done) of \(script.lines.count) recorded · \(session.recordedCount) this session")
					.font(.callout)
					.foregroundStyle(.secondary)
					.monospacedDigit()
			}
			ProgressView(value: Double(done), total: Double(max(script.lines.count, 1)))
		}
	}

	@ViewBuilder
	private func status(session: PracticeSession) -> some View {
		switch session.phase {
		case .ready:
			Text("Press Space, read the line at your normal pace, then press Space again.")
				.foregroundStyle(.secondary)
		case let .recording(startedAt):
			HStack(spacing: 8) {
				Circle().fill(.red).frame(width: 10, height: 10)
				Text("Recording")
				Text(startedAt, style: .timer).monospacedDigit().foregroundStyle(.secondary)
				Text("· Space to stop").foregroundStyle(.secondary)
			}
		case .saving:
			HStack(spacing: 8) {
				ProgressView().controlSize(.small)
				Text("Saving and checking what was heard…").foregroundStyle(.secondary)
			}
		}
	}

	private func controls(session: PracticeSession) -> some View {
		let isRecording: Bool = { if case .recording = session.phase { return true } else { return false } }()
		return HStack {
			Button("Done for now") { store.send(.endSession) }
				.keyboardShortcut(.cancelAction)
			Spacer()
			Button("Skip") { store.send(.skipLine) }
				.disabled(session.phase != .ready || session.line == nil)
			Button(isRecording ? "Stop" : "Record") { store.send(.toggleRecording) }
				.keyboardShortcut(.space, modifiers: [])
				.buttonStyle(.borderedProminent)
				.tint(isRecording ? .red : .accentColor)
				.disabled(session.phase == .saving || session.line == nil)
		}
	}
}

/// What the engine heard for the line just saved, so a bad take can be redone right away.
private struct LastLineView: View {
	var recording: PracticeRecording
	var redo: () -> Void

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			Image(systemName: icon).foregroundStyle(color)
			VStack(alignment: .leading, spacing: 2) {
				Text(summary).font(.callout)
				if let heard = recording.recognized, (recording.wordErrorRate ?? 0) > 0 {
					Text("Heard: \(heard)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
				}
			}
			Spacer()
			Button("Redo", action: redo)
		}
		.padding(10)
		.background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
	}

	private var summary: String {
		guard let rate = recording.wordErrorRate else { return "Saved. The engine couldn't transcribe it, but the recording is kept." }
		if rate == 0 { return "Saved. Every word heard right." }
		let words = WordErrorRate.normalize(recording.text).count
		let errors = Int((rate * Double(words)).rounded())
		return "Saved. \(errors) word\(errors == 1 ? "" : "s") heard differently: the kind of mistake this practice teaches the model to fix."
	}

	private var icon: String {
		guard let rate = recording.wordErrorRate else { return "questionmark.circle" }
		return rate == 0 ? "checkmark.circle.fill" : "checkmark.circle"
	}

	private var color: Color {
		guard let rate = recording.wordErrorRate else { return .secondary }
		return rate == 0 ? .green : .orange
	}
}
