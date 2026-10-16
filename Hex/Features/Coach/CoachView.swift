import AppKit
import Charts
import ComposableArchitecture
import HexCore
import SwiftUI

/// Layout C, the scorecard: one big number with its trend, the weekly chart, smaller numbers, the user's own
/// moments to hear, and tips (mock-ups in `<data root>/bench/coach-mockups/`).
struct CoachView: View {
	@Bindable var store: StoreOf<CoachFeature>

	private var summary: CoachSummary { store.summary }
	private var hasData: Bool { summary.overall.words > 0 }

	var body: some View {
		ScrollView {
			content
		}
		.background(Color(nsColor: .windowBackgroundColor))
		.task { await store.send(.task).finish() }
		.sheet(item: $store.minute) { _ in
			MinuteSheet(store: store)
		}
	}

	/// The scorecard without its scroll view, so a snapshot test can render it whole.
	var content: some View {
			VStack(alignment: .leading, spacing: 14) {
				header
				if let note = store.runNote {
					Label(note, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
				}
				minuteCard
				if hasData {
					if summary.weeks.count >= 2 { chart }
					tiles
					hearYourself
					leanOn
					misheard
					tips
				}
				footer
			}
			.padding(20)
	}

	// MARK: Header

	private var header: some View {
		HStack(alignment: .center, spacing: 18) {
			VStack(alignment: .leading, spacing: 4) {
				Text("Fillers per 100 words").font(.headline).foregroundStyle(.secondary)
				HStack(alignment: .firstTextBaseline, spacing: 10) {
					Text(summary.overall.fillersPer100Words.map { String(format: "%.1f", $0) } ?? "–")
						.font(.system(size: 54, weight: .bold)).monospacedDigit()
					if let trend = CoachTrend(summary) {
						Label(trend.text, systemImage: trend.percent <= 0 ? "arrow.down.right" : "arrow.up.right")
							.font(.callout.weight(.medium))
							.foregroundStyle(trend.percent <= 0 ? .green : .orange)
					}
				}
				Text(hasData
					? "\(summary.overall.dictations) dictations · \(summary.overall.words.formatted()) words"
					: "Run analysis to see how you speak. Parakeet listens to your History recordings again on this Mac; nothing is sent anywhere.")
					.font(.caption).foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			Spacer()
			VStack(alignment: .trailing, spacing: 8) {
				if let progress = store.progress {
					HStack(spacing: 8) {
						ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
							.frame(width: 120)
						Button("Stop") { store.send(.stopAnalysis) }
					}
					Text("\(progress.done) of \(progress.total) recordings").font(.caption).foregroundStyle(.secondary).monospacedDigit()
				} else {
					Button { store.send(.runAnalysis) } label: { Label("Run analysis", systemImage: "play.fill") }
						.buttonStyle(.borderedProminent).controlSize(.large)
						.disabled(store.pending == 0)
					Text(store.pending == 0 ? "Everything is analysed" : "\(store.pending) new recordings to analyse")
						.font(.caption).foregroundStyle(.secondary)
					Button { exportShareCard() } label: { Label("Share card…", systemImage: "square.and.arrow.up") }
						.disabled(!hasData)
				}
			}
		}
		.coachCard()
	}

	// MARK: Filler-free minute

	private var minuteCard: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				Label("Filler-free minute", systemImage: "stopwatch").font(.headline)
				Spacer()
				if let best = store.bestMinute {
					Text("best: \(best.fillerCount) \(best.fillerCount == 1 ? "filler" : "fillers") · \(store.minutes.count) \(store.minutes.count == 1 ? "try" : "tries")")
						.font(.caption).foregroundStyle(.secondary)
				}
			}
			HStack(alignment: .center) {
				Text("Talk for 60 seconds on a topic the app picks, without um, uh or like. Fillers are counted when you stop.")
					.font(.caption).foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				Spacer(minLength: 16)
				Button("Start") { store.send(.startMinute) }.controlSize(.large)
			}
		}
		.coachCard()
	}

	// MARK: Chart

	private var chart: some View {
		Chart(summary.weeks, id: \.start) { week in
			if let rate = week.rates.fillersPer100Words {
				LineMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Fillers", rate)).symbol(.circle)
			}
		}
		.chartYAxisLabel("fillers per 100 words")
		.frame(height: 130)
		.coachCard()
	}

	// MARK: Tiles

	private var tiles: some View {
		let o = summary.overall
		let lastMinute = store.minutes.last
		return Grid(horizontalSpacing: 12, verticalSpacing: 12) {
			GridRow {
				CoachTile(
					value: o.correctionsPer100Words.map { String(format: "%.1f", $0) } ?? "–",
					label: summary.stutterFriendly ? "self-corrections / 100 words, repeats not counted" : "self-corrections / 100 words"
				)
				CoachTile(value: o.speakingWordsPerMinute.map { String(format: "%.0f", $0) } ?? "–", label: "words a minute while speaking")
				CoachTile(
					value: (summary.stutterFriendly ? o.medianSentencePause : o.medianThoughtPause).map { String(format: "%.1f s", $0) } ?? "–",
					label: summary.stutterFriendly ? "typical pause between sentences" : "typical pause"
				)
			}
			GridRow {
				CoachTile(value: o.medianSentenceLength.map { String(format: "%.0f", $0) } ?? "–", label: "words in a typical sentence")
				CoachTile(
					value: "\(summary.recentRunOns)", label: "run-on sentences this week",
					note: "\(CoachText.runOnWords)+ words, \(CoachText.runOnAnds)+ “and”s"
				)
				CoachTile(
					value: lastMinute?.pitchRange.map { String(format: "%.1f st", $0) } ?? "–",
					label: "pitch range (semitones)",
					note: lastMinute == nil ? "from a filler-free minute" : "your last minute"
				)
			}
		}
		.monospacedDigit()
	}

	// MARK: Hear yourself

	private var hearYourself: some View {
		let fillers = summary.examples.filter { $0.moment.kind == .filler }.prefix(3)
		let sentences = summary.examples.filter { $0.moment.kind == .fluent }.prefix(3)
		return VStack(alignment: .leading, spacing: 10) {
			Label("Hear yourself", systemImage: "speaker.wave.2").font(.headline)
			Text("A few seconds from your own recordings. Recordings are kept \(retentionText), so these come from your recent dictations.")
				.font(.caption).foregroundStyle(.secondary)
			HStack(alignment: .top, spacing: 24) {
				VStack(alignment: .leading, spacing: 6) {
					Text("A filler").font(.caption).foregroundStyle(.secondary)
					if fillers.isEmpty { Text("None in your recordings").font(.callout).foregroundStyle(.secondary) }
					ForEach(Array(fillers.enumerated()), id: \.offset) { _, example in
						exampleRow(example, title: "“\(example.moment.label)”")
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				if !summary.stutterFriendly {
					VStack(alignment: .leading, spacing: 6) {
						Text("Said cleanly").font(.caption).foregroundStyle(.secondary)
						if sentences.isEmpty { Text("None found yet").font(.callout).foregroundStyle(.secondary) }
						ForEach(Array(sentences.enumerated()), id: \.offset) { _, example in
							exampleRow(example, title: "a whole sentence")
						}
					}
					.frame(maxWidth: .infinity, alignment: .leading)
				}
			}
		}
		.coachCard()
	}

	private var retentionText: String {
		let days = store.hexSettings.audioRetentionDays
		return days == 0 ? "until you delete them" : "for \(days) days"
	}

	private func exampleRow(_ example: CoachSummary.Example, title: String) -> some View {
		let snippet = CoachFeature.Snippet(dictationID: example.dictationID, time: example.moment.time, seconds: example.moment.seconds)
		return HStack(spacing: 8) {
			playButton(snippet)
			Text(title).font(.callout)
			Text(example.date.formatted(.dateTime.month(.abbreviated).day())).font(.caption).foregroundStyle(.secondary)
		}
	}

	private func playButton(_ snippet: CoachFeature.Snippet) -> some View {
		let playing = store.playing == snippet.id
		return Button {
			store.send(playing ? .stopPlaying : .play(snippet))
		} label: {
			Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill").font(.title3)
		}
		.buttonStyle(.plain)
		.foregroundStyle(Color.accentColor)
		.help(playing ? "Stop" : "Play a few seconds around it")
	}

	// MARK: Words you lean on

	private var leanOn: some View {
		let words = max(summary.overall.words, 1)
		let rows = summary.crutches.prefix(5).map { ($0, CoachMoment.Kind.crutch) } + summary.hedges.prefix(4).map { ($0, CoachMoment.Kind.hedge) }
		let top = rows.map { Double($0.0.count) * 100 / Double(words) }.max() ?? 1
		return VStack(alignment: .leading, spacing: 10) {
			HStack {
				Label("Words you lean on", systemImage: "text.word.spacing").font(.headline)
				Spacer()
				Text("per 100 words").font(.caption).foregroundStyle(.secondary)
			}
			if rows.isEmpty {
				Text("No crutch words or hedges found.").font(.callout).foregroundStyle(.secondary)
			} else {
				HStack(alignment: .top, spacing: 24) {
					leanColumn("Crutch words", summary.crutches.prefix(5), kind: .crutch, words: words, top: top)
					leanColumn("Hedges", summary.hedges.prefix(4), kind: .hedge, words: words, top: top)
				}
			}
		}
		.coachCard()
	}

	private func leanColumn(_ title: String, _ counts: ArraySlice<CoachSummary.Count>, kind: CoachMoment.Kind, words: Int, top: Double) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(title).font(.caption).foregroundStyle(.secondary)
			if counts.isEmpty { Text("None").font(.callout).foregroundStyle(.secondary) }
			ForEach(Array(counts), id: \.name) { count in
				let rate = Double(count.count) * 100 / Double(words)
				HStack(spacing: 8) {
					if let example = summary.examples.first(where: { $0.moment.kind == kind && $0.moment.label == count.name }) {
						playButton(CoachFeature.Snippet(dictationID: example.dictationID, time: example.moment.time))
					} else {
						Image(systemName: "play.circle").font(.title3).foregroundStyle(.quaternary)
					}
					Text(count.name).frame(width: 78, alignment: .leading)
					GeometryReader { g in
						RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.7))
							.frame(width: g.size.width * min(1, rate / max(top, 0.01)))
					}
					.frame(height: 9)
					Text(String(format: "%.1f", rate)).monospacedDigit().frame(width: 30, alignment: .trailing)
				}
				.font(.callout)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	// MARK: Say these more clearly

	private var misheard: some View {
		VStack(alignment: .leading, spacing: 10) {
			Label("Say these more clearly", systemImage: "ear").font(.headline)
			if summary.misheard.isEmpty {
				Text("Nothing yet. A word shows up here when you fix it before sending and neither speech engine heard it right.")
					.font(.callout).foregroundStyle(.secondary)
			} else {
				Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
					GridRow {
						Text("You said").font(.caption).foregroundStyle(.secondary)
						Text("Heard as").font(.caption).foregroundStyle(.secondary)
						Text("Times").font(.caption).foregroundStyle(.secondary)
					}
					ForEach(Array(summary.misheard.prefix(8).enumerated()), id: \.offset) { _, row in
						GridRow {
							Text(row.said).bold()
							Text(row.heard)
							Text("\(row.count)").monospacedDigit()
						}
					}
				}
				.font(.callout)
				Text("Two different speech engines both got these wrong, so it's likely how they were said. Names in your Vocabulary aren't listed.")
					.font(.caption).foregroundStyle(.secondary)
			}
		}
		.coachCard()
	}

	// MARK: Tips

	private var tips: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Try this week").font(.headline)
			ForEach(summary.tips, id: \.self) { tip in
				HStack(alignment: .top, spacing: 10) {
					Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
					Text(tip).font(.callout).fixedSize(horizontal: false, vertical: true)
				}
				.padding(12).frame(maxWidth: .infinity, alignment: .leading)
				.background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.12)))
			}
		}
	}

	private var footer: some View {
		VStack(alignment: .leading, spacing: 4) {
			Toggle("I stutter", isOn: Binding(
				get: { store.hexSettings.coachStutterFriendly },
				set: { store.send(.setStutterFriendly($0)) }
			))
			Text("Repeated words and pauses inside sentences aren't counted against you, and pace and pause tips are left out.")
				.font(.caption).foregroundStyle(.secondary)
		}
		.coachCard()
	}

	// MARK: Share card

	@MainActor
	private func exportShareCard() {
		let renderer = ImageRenderer(content: CoachShareCard(summary: summary, best: store.bestMinute))
		renderer.scale = 2
		guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
		      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
		else { return }
		let panel = NSSavePanel()
		panel.allowedContentTypes = [.png]
		panel.nameFieldStringValue = "Speech Coach \(Date().formatted(.iso8601.year().month().day())).png"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		do {
			try png.write(to: url)
		} catch {
			HexLog.coach.error("Share card not saved: \(error.localizedDescription, privacy: .public)")
		}
	}
}

/// The change in fillers per 100 words from up to four weeks back to the latest week.
struct CoachTrend {
	var percent: Int
	var weeksAgo: Int

	init?(_ summary: CoachSummary) {
		let weeks = summary.weeks.filter { $0.rates.words >= 100 }
		guard weeks.count >= 2, let last = weeks.last else { return nil }
		let base = weeks[max(0, weeks.count - 5)]
		guard let before = base.rates.fillersPer100Words, before > 0, let now = last.rates.fillersPer100Words else { return nil }
		percent = Int(((now - before) / before * 100).rounded())
		weeksAgo = max(1, Int((last.start.timeIntervalSince(base.start) / (7 * 86400)).rounded()))
	}

	var text: String {
		let span = weeksAgo == 1 ? "last week" : "\(weeksAgo) weeks ago"
		if percent == 0 { return "same as \(span)" }
		return "\(abs(percent))% \(percent < 0 ? "fewer" : "more") than \(span)"
	}
}

private struct CoachTile: View {
	let value: String
	let label: String
	var note: String? = nil

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(value).font(.system(size: 24, weight: .semibold))
			Text(label).font(.caption).foregroundStyle(.secondary)
			if let note { Text(note).font(.caption.weight(.medium)).foregroundStyle(.orange) }
		}
		.padding(12)
		.frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
		.background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
		.overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.09)))
	}
}

private extension View {
	/// Like a grouped form's section (Practice, Notes, Settings): a faint fill and hairline on the window
	/// background, so cards stand out in light and dark (option B in `coach-mockups/look.png`).
	func coachCard() -> some View {
		let shape = RoundedRectangle(cornerRadius: 12)
		return padding(14)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(shape.fill(Color.primary.opacity(0.045)))
			.overlay(shape.strokeBorder(Color.primary.opacity(0.09)))
	}
}

// MARK: - Filler-free minute sheet

private struct MinuteSheet: View {
	@Bindable var store: StoreOf<CoachFeature>

	var body: some View {
		if let session = store.minute {
			VStack(spacing: 18) {
				Text("Filler-free minute").font(.headline).foregroundStyle(.secondary)
				switch session.phase {
				case .ready:
					topic(session.topic)
					Text("Talk about it for a minute, as if to a friend. Parakeet counts the fillers on this Mac when you stop.")
						.font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
					HStack {
						Button("Another topic") { store.send(.anotherTopic) }
						Button("Start") { store.send(.toggleMinuteRecording) }
							.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
					}
					.controlSize(.large)
				case let .recording(startedAt):
					topic(session.topic)
					Countdown(startedAt: startedAt)
					Button("Stop") { store.send(.toggleMinuteRecording) }
						.controlSize(.large).keyboardShortcut(.defaultAction)
				case .scoring:
					ProgressView("Counting…").padding(40)
				case let .result(minute, previousBest):
					MinuteResult(minute: minute, previousBest: previousBest, store: store)
				case let .failed(message):
					Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
					Button("Try again") { store.send(.toggleMinuteRecording) }.controlSize(.large)
				}
				HStack {
					Spacer()
					Button("Done") { store.send(.closeMinute) }.keyboardShortcut(.cancelAction)
				}
			}
			.padding(24)
			.frame(width: 460)
		}
	}

	private func topic(_ text: String) -> some View {
		Text(text).font(.system(size: 22, weight: .semibold)).multilineTextAlignment(.center)
			.fixedSize(horizontal: false, vertical: true)
	}
}

private struct Countdown: View {
	let startedAt: Date

	var body: some View {
		TimelineView(.periodic(from: startedAt, by: 0.25)) { context in
			let elapsed = min(CoachMinute.seconds, context.date.timeIntervalSince(startedAt))
			let left = Int((CoachMinute.seconds - elapsed).rounded(.up))
			ZStack {
				Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 10)
				Circle().trim(from: 0, to: elapsed / CoachMinute.seconds)
					.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
					.rotationEffect(.degrees(-90))
				VStack(spacing: 0) {
					Text(String(format: "%d:%02d", left / 60, left % 60)).font(.system(size: 34, weight: .bold)).monospacedDigit()
					Text("left").font(.caption).foregroundStyle(.secondary)
				}
			}
			.frame(width: 130, height: 130)
		}
	}
}

private struct MinuteResult: View {
	let minute: CoachMinute
	let previousBest: CoachMinute?
	@Bindable var store: StoreOf<CoachFeature>

	private var isNewBest: Bool {
		guard minute.words >= 60 else { return false }
		guard let previousBest else { return true }
		return (minute.fillerCount, -minute.words) < (previousBest.fillerCount, -previousBest.words)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Text("\(minute.fillerCount)").font(.system(size: 48, weight: .bold))
					.foregroundStyle(minute.fillerCount == 0 ? .green : .primary)
				VStack(alignment: .leading) {
					Text(minute.fillerCount == 1 ? "filler in 60 s" : "fillers in 60 s").font(.headline)
					if isNewBest {
						Label(previousBest.map { "New best (was \($0.fillerCount))" } ?? "Your first score", systemImage: "trophy.fill")
							.font(.callout).foregroundStyle(.orange)
					} else if minute.words < 60 {
						Text("Under 60 words doesn't count toward a best: keep talking for the whole minute.")
							.font(.caption).foregroundStyle(.secondary)
					}
				}
			}
			HStack(spacing: 16) {
				stat(minute.wordsPerMinute.map { String(format: "%.0f", $0) } ?? "–", "words a minute")
				stat("\(minute.crutchCount)", "crutch words")
				stat("\(minute.hedgeCount)", "hedges")
				stat(minute.pitchRange.map { String(format: "%.1f st", $0) } ?? "–", "pitch range")
			}
			Divider()
			ScrollView {
				Text(highlighted).font(.callout).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
			}
			.frame(maxHeight: 140)
			HStack {
				Button(store.playing == "minute" ? "Stop" : "Play it back") {
					store.send(store.playing == "minute" ? .stopPlaying : .playMinute)
				}
				.disabled(store.minute?.audio == nil)
				Spacer()
				Button("Another topic") {
					store.send(.anotherTopic)
					store.send(.toggleMinuteRecording)
				}
				Button("Try again") { store.send(.toggleMinuteRecording) }
			}
		}
	}

	private func stat(_ value: String, _ label: String) -> some View {
		VStack(alignment: .leading) {
			Text(value).bold().monospacedDigit()
			Text(label).font(.caption).foregroundStyle(.secondary)
		}
	}

	/// Fillers, crutch words and hedges in orange.
	private var highlighted: AttributedString {
		let words = minute.text.split(separator: " ").map(String.init)
		let result = CoachText.analyse(words)
		var marked = Set(result.fillers.map(\.index))
		for (index, kind) in result.crutches {
			marked.formUnion(index ..< index + kind.rawValue.split(separator: " ").count)
		}
		for (index, kind) in result.hedges {
			marked.formUnion(index ..< index + kind.rawValue.split(separator: " ").count)
		}
		var text = AttributedString()
		for (index, word) in words.enumerated() {
			var piece = AttributedString(index == 0 ? word : " " + word)
			if marked.contains(index) {
				piece.foregroundColor = .orange
				piece.font = .callout.bold()
			}
			text += piece
		}
		return text
	}
}

// MARK: - Share card

/// The scorecard as a picture for the poster or a message: numbers only, never audio or text.
struct CoachShareCard: View {
	let summary: CoachSummary
	let best: CoachMinute?

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack {
				Image(systemName: "waveform").foregroundStyle(Color.accentColor)
				Text("LegacyScribe · Speech Coach").font(.callout.weight(.semibold))
				Spacer()
				if let first = summary.weeks.first?.start {
					Text("\(first.formatted(.dateTime.month(.abbreviated).day())) – \(Date().formatted(.dateTime.month(.abbreviated).day()))")
						.font(.caption).foregroundStyle(.secondary)
				}
			}
			Text("Fillers per 100 words").font(.headline).foregroundStyle(.secondary)
			HStack(alignment: .firstTextBaseline, spacing: 12) {
				Text(summary.overall.fillersPer100Words.map { String(format: "%.1f", $0) } ?? "–")
					.font(.system(size: 72, weight: .bold)).monospacedDigit()
				if let trend = CoachTrend(summary) {
					Label(trend.text, systemImage: trend.percent <= 0 ? "arrow.down.right" : "arrow.up.right")
						.font(.title3.weight(.medium)).foregroundStyle(trend.percent <= 0 ? .green : .orange)
				}
			}
			if summary.weeks.count >= 2 {
				Chart(summary.weeks, id: \.start) { week in
					if let rate = week.rates.fillersPer100Words {
						AreaMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Fillers", rate))
							.foregroundStyle(Color.accentColor.opacity(0.15))
						LineMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Fillers", rate)).symbol(.circle)
					}
				}
				.chartYAxis(.hidden)
				.frame(height: 110)
			}
			HStack(spacing: 12) {
				stat(summary.overall.speakingWordsPerMinute.map { String(format: "%.0f", $0) } ?? "–", "wpm speaking")
				stat(summary.overall.correctionsPer100Words.map { String(format: "%.1f", $0) } ?? "–", "corrections / 100")
				stat(best.map { "\($0.fillerCount) \($0.fillerCount == 1 ? "filler" : "fillers")" } ?? "–", "best minute")
			}
			Text("\(summary.overall.dictations) dictations, analysed on this Mac. Nothing sent anywhere.")
				.font(.caption).foregroundStyle(.secondary)
		}
		.padding(24)
		.frame(width: 540)
		.background(RoundedRectangle(cornerRadius: 16).fill(.white))
		.padding(20)
		.background(Color(white: 0.93))
		.environment(\.colorScheme, .light)
	}

	private func stat(_ value: String, _ label: String) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit()
			Text(label).font(.caption).foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}
