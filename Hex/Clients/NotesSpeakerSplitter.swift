import FluidAudio
import Foundation
import HexCore

/// Who spoke when in a notes chunk, and voice embeddings for enrolment: FluidAudio's diarizer (pyannote
/// segmentation + WeSpeaker v2, 256-d), downloaded once into `<data root>/Models/fluidaudio/speaker-diarization`
/// (the folder `lsbench voice` uses). Another per-session model next to `NotesVoiceDetector`.
actor NotesSpeakerSplitter {
	/// `DiarizerManager` isn't Sendable; it only ever runs on this actor.
	private final class Diarizer: @unchecked Sendable {
		let manager: DiarizerManager
		init(_ manager: DiarizerManager) { self.manager = manager }
	}

	private var diarizer: Diarizer?
	private var loading: Task<Diarizer, Error>?
	/// After a failed load (offline, Private mode) chunks go unlabelled for a while instead of each one
	/// waiting on another download attempt.
	private var failedAt: Date?
	private static let retryAfter: TimeInterval = 5 * 60
	/// WeSpeaker sees 10 s at a time; longer audio is averaged over 10 s pieces.
	private static let embeddingWindow = 160_000
	private let logger = HexLog.notes

	struct Unavailable: LocalizedError {
		var errorDescription: String? { "The speaker model isn't available right now" }
	}

	/// Loads the model (downloading it the first time). Safe to call more than once.
	func prepare() async throws {
		_ = try await load()
	}

	/// The chunk's diarizer segments (16 kHz mono), each embedding scaled to unit length (the diarizer's aren't).
	func segments(in samples: [Float]) async throws -> [SpeakerSegment] {
		let manager = try await load().manager
		let rate = NotesChunker.sampleRate
		// Each chunk is diarized on its own; `SpeakerRegistry` carries speakers across chunks. Without the
		// reset FluidAudio's own speaker database would grow through a 2-hour session.
		manager.speakerManager.reset()
		let result = try manager.performCompleteDiarization(samples, sampleRate: rate)
		return result.segments.compactMap { segment in
			let lower = max(0, Int(segment.startTimeSeconds * Float(rate)))
			let upper = min(samples.count, Int(segment.endTimeSeconds * Float(rate)))
			guard upper > lower else { return nil }
			return SpeakerSegment(
				localSpeaker: segment.speakerId,
				range: lower ..< upper,
				embedding: Voiceprint.normalized(segment.embedding)
			)
		}
	}

	/// One voice's embedding: the normalized mean over 10 s pieces (a tail under 1 s is dropped unless it is
	/// all there is).
	func embed(_ samples: [Float]) async throws -> [Float] {
		let manager = try await load().manager
		let window = Self.embeddingWindow
		let minimum = NotesChunker.sampleRate
		let pieces = stride(from: 0, to: samples.count, by: window)
			.map { samples[$0 ..< min(samples.count, $0 + window)] }
			.filter { $0.count >= minimum || samples.count < minimum }
		return Voiceprint.normalizedMean(try pieces.map { try manager.extractSpeakerEmbedding(from: Array($0)) })
	}

	/// Each window of `samples` scored against `voiceprint` (cosine), for `SpeakerOverlap`.
	func scores(_ samples: [Float], windows: [Range<Int>], against voiceprint: [Float]) async throws -> [Float] {
		let manager = try await load().manager
		return try windows.map { window in
			Voiceprint.cosine(try manager.extractSpeakerEmbedding(from: Array(samples[window])), voiceprint)
		}
	}

	private func load() async throws -> Diarizer {
		if let diarizer { return diarizer }
		if let loading { return try await loading.value }
		if let failedAt, Date().timeIntervalSince(failedAt) < Self.retryAfter { throw Unavailable() }
		let task = Task {
			let directory = try URL.hexParakeetModelsDirectory.appendingPathComponent("speaker-diarization", isDirectory: true)
			let models = try await DiarizerModels.download(to: directory)
			let manager = DiarizerManager()
			manager.initialize(models: models)
			return Diarizer(manager)
		}
		loading = task
		do {
			let diarizer = try await task.value
			self.diarizer = diarizer
			loading = nil
			logger.notice("Notes speaker model loaded")
			return diarizer
		} catch {
			loading = nil
			failedAt = Date()
			throw error
		}
	}
}
