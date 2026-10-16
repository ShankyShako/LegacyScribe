import FluidAudio
import Foundation
import HexCore

/// Learns the user's voiceprint from their History recordings (on request, never automatically) and saves
/// it as `you`, replacing any earlier one. Each recording's speech (Silero) is embedded by WeSpeaker; the
/// voiceprint is their normalized mean.
struct VoiceprintEnroller {
	let store: VoiceprintStore
	let splitter: NotesSpeakerSplitter
	let voice: NotesVoiceDetector
	private let logger = HexLog.notes

	/// Up to this many recordings, spread over the History.
	static let maxSources = 40
	static let minimumSources = 5
	/// Shorter dictations carry too little voice to be worth a source.
	static let minimumSeconds: TimeInterval = 3

	enum Failure: LocalizedError, Equatable {
		case tooFewRecordings

		var errorDescription: String? {
			switch self {
			case .tooFewRecordings: "Dictate a few more times first"
			}
		}
	}

	init(store: VoiceprintStore, splitter: NotesSpeakerSplitter, voice: NotesVoiceDetector) {
		self.store = store
		self.splitter = splitter
		self.voice = voice
	}

	/// The History recordings that can be used: transcribed, still on disk, at least 3 s; oldest first, up
	/// to `maxSources` taken evenly across them.
	static func sources(_ history: [Transcript]) -> [URL] {
		let usable = history
			.filter {
				$0.failure == nil && $0.audioRemoved != true && $0.duration >= minimumSeconds
					&& FileManager.default.fileExists(atPath: $0.audioPath.path)
			}
			.sorted { $0.timestamp < $1.timestamp }
			.map(\.audioPath)
		return spread(usable, count: maxSources)
	}

	/// `count` items taken at an even stride (all of them when there are fewer).
	static func spread<T>(_ items: [T], count: Int) -> [T] {
		guard items.count > count else { return items }
		let step = Double(items.count) / Double(count)
		return (0 ..< count).map { items[Int(Double($0) * step)] }
	}

	func enrolUser(history: [Transcript], progress: (@Sendable (Double) -> Void)? = nil) async throws -> Voiceprint {
		try await enrolUser(recordings: Self.sources(history), progress: progress)
	}

	/// Enrols from the given recordings (any format AVFoundation reads; FLAC included). Recordings that
	/// can't be read, or have no speech, are skipped. `progress` gets the fraction of recordings done.
	func enrolUser(recordings: [URL], progress: (@Sendable (Double) -> Void)? = nil) async throws -> Voiceprint {
		let rate = NotesChunker.sampleRate
		var embeddings: [[Float]] = []
		var seconds = 0.0
		for (index, url) in recordings.enumerated() {
			defer { progress?(Double(index + 1) / Double(recordings.count)) }
			do {
				let samples = try AudioConverter().resampleAudioFile(url)
				let ranges = try await voice.speechRanges(in: samples)
				guard let speech = NotesSpeech.joined(samples, ranges: ranges) else { continue }
				embeddings.append(try await splitter.embed(speech))
				seconds += Double(speech.count) / Double(rate)
			} catch {
				logger.error("Voiceprint source skipped: \(error.localizedDescription, privacy: .public)")
			}
		}
		guard embeddings.count >= Self.minimumSources else { throw Failure.tooFewRecordings }

		let embedding = Voiceprint.normalizedMean(embeddings)
		let scores = embeddings.map { Voiceprint.cosine($0, embedding) }.sorted()
		let voiceprint = Voiceprint(
			id: Voiceprint.userID,
			name: nil,
			isUser: true,
			embedding: embedding,
			enrolledAt: Date(),
			sourceCount: embeddings.count,
			sourceSeconds: seconds,
			selfScoreMedian: scores[scores.count / 2]
		)
		try store.save(voiceprint)
		logger.notice("Voiceprint learned from \(embeddings.count) recordings, \(Int(seconds)) s of speech, self-score median \(voiceprint.selfScoreMedian, format: .fixed(precision: 2))")
		return voiceprint
	}
}

extension URL {
	/// `<data root>/Voiceprints/`: one JSON file per voiceprint.
	static var voiceprintsFolderURL: URL {
		(try? URL.hexApplicationSupport.appending(component: "Voiceprints", directoryHint: .isDirectory))
			?? URL.documentsDirectory.appending(component: "Voiceprints", directoryHint: .isDirectory)
	}
}
