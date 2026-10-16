import AVFoundation
import Dependencies
import DependenciesMacros
import FluidAudio
import Foundation
import HexCore

/// How far a Run analysis has got.
struct CoachProgress: Equatable, Sendable {
	var done: Int
	var total: Int
	var failed: Int
}

/// The speech coach's work (P3.6 D6): Parakeet (or Apple Speech) listens to History recordings again, the
/// stats go to `coach_clips`, and the filler-free minute is scored. Nothing runs unless the user asks.
@DependencyClient
struct CoachClient {
	var clips: @Sendable () async throws -> [CoachClip]
	/// Oldest first.
	var minutes: @Sendable () async throws -> [CoachMinute]
	/// How many History recordings the next run would analyse.
	var pending: @Sendable (_ history: [Transcript]) async -> Int = { _ in 0 }
	/// Analyses every History recording without current stats, saving each as it's done, so a stopped run
	/// keeps what it finished. Yields progress; throws only when no engine can transcribe at all.
	var analyse: @Sendable (_ history: [Transcript], _ sentEdits: [SentEdit], _ selectedModel: String)
		-> AsyncThrowingStream<CoachProgress, Error> = { _, _, _ in .finished() }
	/// Scores and saves one filler-free minute.
	var scoreMinute: @Sendable (_ audio: URL, _ topic: String, _ selectedModel: String) async throws -> CoachMinute
	/// Plays `seconds` of the recording from `from`; returns when done. Cancelling stops it.
	var play: @Sendable (_ audio: URL, _ from: Double, _ seconds: Double) async throws -> Void
	/// Deletes the stats and minute results. History and the voiceprint stay.
	var deleteData: @Sendable () async throws -> Void
}

extension CoachClient: DependencyKey {
	static var liveValue: Self {
		let store = { ScribeStore.app }
		return Self(
			clips: { try store().coachClips() },
			minutes: { try store().coachMinutes() },
			pending: { history in
				let current = (try? store().coachClips())?.filter { $0.version >= CoachClip.currentVersion }.map(\.dictationID) ?? []
				return CoachAnalysis.toAnalyse(history, analysed: Set(current)).count
			},
			analyse: { history, sentEdits, selectedModel in
				AsyncThrowingStream { continuation in
					let task = Task {
						do {
							try await CoachAnalysis.run(history: history, sentEdits: sentEdits, selectedModel: selectedModel, store: store()) {
								continuation.yield($0)
							}
							continuation.finish()
						} catch {
							continuation.finish(throwing: error)
						}
					}
					continuation.onTermination = { _ in task.cancel() }
				}
			},
			scoreMinute: { audio, topic, selectedModel in
				@Dependency(\.transcription) var transcription
				let heard = try await transcription.coachWords(audio, selectedModel)
				let samples = try AudioConverter().resampleAudioFile(audio)
				let minute = CoachMinute.score(topic: topic, engine: heard.engine, words: heard.words, samples: samples, sampleRate: 16_000)
				try store().saveCoachMinute(minute)
				return minute
			},
			play: { audio, from, seconds in
				try await SnippetPlayer.shared.play(audio, from: from, seconds: seconds)
			},
			deleteData: { try store().deleteCoachClips() }
		)
	}
}

extension CoachClient: TestDependencyKey {
	/// Every endpoint unimplemented, so a test states what the coach does.
	static let testValue = Self()
}

extension DependencyValues {
	var coach: CoachClient {
		get { self[CoachClient.self] }
		set { self[CoachClient.self] = newValue }
	}
}

enum CoachAnalysis {
	private static let log = HexLog.coach

	/// Entries whose recording can still be analysed and that have no current stats.
	static func toAnalyse(_ history: [Transcript], analysed: Set<UUID>) -> [Transcript] {
		history.filter { transcript in
			transcript.failure == nil && transcript.audioRemoved != true && !analysed.contains(transcript.id)
				&& FileManager.default.fileExists(atPath: transcript.audioPath.path)
		}
	}

	static func run(
		history: [Transcript], sentEdits: [SentEdit], selectedModel: String, store: ScribeStore,
		progress: @escaping (CoachProgress) -> Void
	) async throws {
		@Dependency(\.transcription) var transcription
		let current = try store.coachClips().filter { $0.version >= CoachClip.currentVersion }.map(\.dictationID)
		let todo = toAnalyse(history, analysed: Set(current))
		let editByDictation = Dictionary(sentEdits.compactMap { edit in edit.transcriptID.map { ($0, edit) } }) { _, newer in newer }
		var state = CoachProgress(done: 0, total: todo.count, failed: 0)
		progress(state)
		let started = Date()
		for transcript in todo {
			try Task.checkCancellation()
			do {
				let heard = try await transcription.coachWords(transcript.audioPath, selectedModel)
				let samples = try AudioConverter().resampleAudioFile(transcript.audioPath)
				let clip = SpeechCoach.clip(
					for: transcript, engine: heard.engine, words: heard.words, samples: samples, sampleRate: 16_000,
					sentEdit: editByDictation[transcript.id], dictationEngine: transcript.latency?.engine
				)
				try store.saveCoachClips([clip])
			} catch let error as NSError where error.domain == "TranscriptionClient" && error.code == -6 {
				throw error
			} catch is CancellationError {
				throw CancellationError()
			} catch {
				state.failed += 1
				log.error("Coach analysis of \(transcript.audioPath.lastPathComponent, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
			}
			state.done += 1
			progress(state)
		}
		log.notice("Coach analysed \(state.done) recordings (\(state.failed) failed) in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
	}
}

/// Plays a stretch of a recording: a snippet around a moment, or a whole filler-free minute.
@MainActor
final class SnippetPlayer {
	static let shared = SnippetPlayer()
	/// A snippet starts this long before its moment, so the listener catches the sentence around it.
	static let leadIn = 1.5
	static let snippetSeconds = 4.0
	/// A moment played whole (a clean sentence) starts this much early and runs this much past its end.
	static let wholeLeadIn = 0.2
	static let wholeTail = 0.4

	private var player: AVAudioPlayer?

	func play(_ url: URL, from start: Double, seconds: Double) async throws {
		stop()
		let player = try AVAudioPlayer(contentsOf: url)
		self.player = player
		player.currentTime = max(0, start)
		player.play()
		defer { if self.player === player { stop() } }
		try await Task.sleep(for: .seconds(max(0, min(seconds, player.duration - player.currentTime))))
	}

	func stop() {
		player?.stop()
		player = nil
	}
}
