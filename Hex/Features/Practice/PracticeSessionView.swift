import ComposableArchitecture
import HexCore
import SwiftUI

/// One line at a time: tap Space (or the big button) to record and again to save, or hold Space for
/// 2 s or more and let go to save. Every saved line is kept, so "Done for now" (or Escape) loses nothing.
struct PracticeSessionView: View {
	@Bindable var store: StoreOf<PracticeFeature>
	/// The dictation pipeline's input meter, which also runs while a practice line records.
	var transcription: StoreOf<TranscriptionFeature>
	@State private var spaceMonitor: Any?

	var body: some View {
		VStack(spacing: 0) {
			if let session = store.session {
				header(session: session)
				if let pick = session.current {
					Spacer(minLength: 16)
					Text(pick.line.text)
						.font(.system(size: 28, weight: .medium))
						.multilineTextAlignment(.center)
						.lineSpacing(4)
						.frame(maxWidth: 560, minHeight: 110)
						.textSelection(.enabled)
						.id(pick.id)
						.transition(.opacity)
					Spacer(minLength: 20)
					RecordButton(phase: session.phase, transcription: transcription) {
						store.send(.toggleRecording)
					}
					status(session: session)
						.frame(height: 22)
						.padding(.top, 10)
					Spacer(minLength: 16)
				} else {
					Spacer()
					finished(session: session)
					Spacer()
				}
				if let error = session.error {
					Text(error).font(.callout).foregroundStyle(.red).padding(.bottom, 8)
				}
				if let last = session.lastRecording {
					LastLineView(recording: last) { store.send(.redoLast) }
						.padding(.bottom, 14)
				}
				controls(session: session)
			}
		}
		.animation(.easeOut(duration: 0.18), value: store.session?.current?.id)
		.padding(24)
		.frame(width: 640, height: 540)
		.onAppear { startSpaceMonitor() }
		.onDisappear { stopSpaceMonitor() }
	}

	/// Space is read as key-down and key-up instead of a button shortcut: a held key auto-repeats, and
	/// each repeat would press the button again.
	private func startSpaceMonitor() {
		guard spaceMonitor == nil else { return }
		spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [store] event in
			guard event.keyCode == 49,
			      event.modifierFlags.isDisjoint(with: [.command, .control, .option])
			else { return event }
			if event.type == .keyUp {
				store.send(.spaceUp)
			} else if !event.isARepeat {
				store.send(.spaceDown)
			}
			return nil
		}
	}

	private func stopSpaceMonitor() {
		if let spaceMonitor {
			NSEvent.removeMonitor(spaceMonitor)
		}
		spaceMonitor = nil
	}

	private func header(session: PracticeSession) -> some View {
		HStack {
			Text(session.current?.role.title ?? (session.isEndless ? "Endless" : "Set done"))
				.font(.headline)
			Spacer()
			if session.isEndless {
				Text("Endless · \(session.results.count) read")
					.font(.callout)
					.foregroundStyle(.secondary)
					.monospacedDigit()
			} else {
				SetProgress(count: session.picks.count, position: session.index)
			}
		}
	}

	@ViewBuilder
	private func status(session: PracticeSession) -> some View {
		switch session.phase {
		case .ready:
			Text("Tap Space, read the line, tap Space again. Or hold Space while you read and let go.")
				.foregroundStyle(.secondary)
		case let .recording(startedAt):
			HStack(spacing: 6) {
				Text(startedAt, style: .timer).monospacedDigit()
				Text("· Space to stop")
			}
			.foregroundStyle(.secondary)
		case .saving:
			Text("Saving…").foregroundStyle(.secondary)
		}
	}

	private func finished(session: PracticeSession) -> some View {
		VStack(spacing: 10) {
			Image(systemName: "checkmark.circle.fill")
				.font(.system(size: 44))
				.foregroundStyle(.green)
			if session.isEndless {
				Text("You've recorded every line.").font(.title2)
			} else {
				Text(Self.setSummary(session)).font(.title2)
			}
			if !session.isEndless {
				Button("Another set") { store.send(.startSession(endless: false)) }
					.buttonStyle(.borderedProminent)
					.controlSize(.large)
					.keyboardShortcut(.defaultAction)
					.padding(.top, 6)
			}
		}
	}

	static func setSummary(_ session: PracticeSession) -> String {
		let read = session.results.count
		guard read > 0 else { return "No lines recorded in this set." }
		let lines = read == 1 ? "1 line" : "\(read) lines"
		return "\(lines) read, \(session.perfectCount) heard word for word."
	}

	private func controls(session: PracticeSession) -> some View {
		HStack {
			Button("Done for now") { store.send(.endSession) }
				.keyboardShortcut(.cancelAction)
			Spacer()
			if session.current != nil {
				Button("Skip") { store.send(.skipLine) }
					.disabled(session.phase != .ready)
			}
		}
		.controlSize(.large)
	}
}

/// The big round button in the middle. Breathes while waiting; while recording, the halo follows the
/// microphone level.
private struct RecordButton: View {
	var phase: PracticeSession.Phase
	var transcription: StoreOf<TranscriptionFeature>
	var action: () -> Void

	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	private var isRecording: Bool {
		if case .recording = phase { true } else { false }
	}

	var body: some View {
		let tint: Color = isRecording ? .red : .accentColor
		Button(action: action) {
			ZStack {
				halo(tint: tint)
				Circle()
					.fill(tint)
					.frame(width: 92, height: 92)
					.shadow(color: tint.opacity(0.35), radius: 10, y: 3)
				if phase == .saving {
					ProgressView()
						.controlSize(.regular)
						.tint(.white)
				} else {
					Image(systemName: isRecording ? "stop.fill" : "mic.fill")
						.font(.system(size: 34, weight: .semibold))
						.foregroundStyle(.white)
						.contentTransition(.symbolEffect(.replace))
				}
			}
			.frame(width: 140, height: 140)
			.contentShape(Circle())
		}
		.buttonStyle(PressScale())
		.disabled(phase == .saving)
		.accessibilityLabel(isRecording ? "Stop and save" : "Record")
	}

	@ViewBuilder
	private func halo(tint: Color) -> some View {
		let circle = Circle()
			.fill(tint.opacity(isRecording ? 0.25 : 0.15))
			.frame(width: 136, height: 136)
		if isRecording {
			let level = min(1, transcription.meter.averagePower * 3)
			circle
				.scaleEffect(0.8 + 0.4 * level)
				.animation(.easeOut(duration: 0.12), value: level)
		} else if reduceMotion || phase == .saving {
			circle.scaleEffect(0.9)
		} else {
			circle.phaseAnimator([0.86, 1.0]) { content, scale in
				content.scaleEffect(scale)
			} animation: { _ in
				.easeInOut(duration: 1.6)
			}
		}
	}
}

private struct PressScale: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.scaleEffect(configuration.isPressed ? 0.94 : 1)
			.animation(.easeOut(duration: 0.12), value: configuration.isPressed)
	}
}

/// One dot per line in the set: done, current, to come.
private struct SetProgress: View {
	var count: Int
	var position: Int

	var body: some View {
		HStack(spacing: 10) {
			HStack(spacing: 5) {
				ForEach(0 ..< count, id: \.self) { index in
					Circle()
						.fill(index < position ? Color.accentColor : Color.secondary.opacity(index == position ? 0.6 : 0.25))
						.frame(width: 7, height: 7)
				}
			}
			Text("\(min(position + 1, count)) of \(count)")
				.font(.callout)
				.foregroundStyle(.secondary)
				.monospacedDigit()
		}
		.accessibilityElement(children: .ignore)
		.accessibilityLabel("Line \(min(position + 1, count)) of \(count)")
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
				.controlSize(.large)
		}
		.padding(10)
		.background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
	}

	private var summary: String {
		guard let rate = recording.wordErrorRate else { return "Saved, but the engine couldn't transcribe it. The audio is kept." }
		if rate == 0 { return "Saved. Every word heard right." }
		let words = WordErrorRate.normalize(recording.text).count
		let errors = Int((rate * Double(words)).rounded())
		return "Saved. \(errors) word\(errors == 1 ? "" : "s") heard differently."
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
