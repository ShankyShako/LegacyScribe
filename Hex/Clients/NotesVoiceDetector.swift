import FluidAudio
import Foundation
import HexCore

/// Finds the speech in a notes chunk with Silero VAD (FluidAudio's Core ML port, ~1 MB, downloaded once
/// into `<data root>/Models/fluidaudio/silero-vad`). See `NotesSpeech` for why.
actor NotesVoiceDetector {
	private var manager: VadManager?
	private var loading: Task<VadManager, Error>?
	/// After a failed load (offline on first use, say) chunks are transcribed whole for a while instead of
	/// each one waiting on another download attempt.
	private var failedAt: Date?
	private static let retryAfter: TimeInterval = 5 * 60
	private let logger = HexLog.notes

	/// Speech is padded so word edges aren't clipped; a stretch shorter than a syllable is ignored.
	/// FluidAudio asserts (Debug builds) that the padding is no longer than the shortest speech.
	private let segmentation = VadSegmentationConfig(minSpeechDuration: 0.3, speechPadding: 0.3)

	/// Loads the model (downloading it the first time). Safe to call more than once.
	func prepare() async throws {
		_ = try await load()
	}

	/// Sample ranges of speech in 16 kHz mono `samples`.
	func speechRanges(in samples: [Float]) async throws -> [Range<Int>] {
		let manager = try await load()
		let rate = VadManager.sampleRate
		return try await manager.segmentSpeech(samples, config: segmentation).map {
			$0.startSample(sampleRate: rate) ..< $0.endSample(sampleRate: rate)
		}
	}

	private func load() async throws -> VadManager {
		if let manager { return manager }
		if let loading { return try await loading.value }
		if let failedAt, Date().timeIntervalSince(failedAt) < Self.retryAfter { throw VadError.modelLoadingFailed }
		let task = Task {
			let models = try await ModelHub.loadModels(
				.vad,
				modelNames: Array(ModelNames.VAD.requiredModels),
				directory: try URL.hexParakeetModelsDirectory
			)
			guard let model = models[ModelNames.VAD.sileroVadFile] else { throw VadError.modelLoadingFailed }
			return VadManager(vadModel: model)
		}
		loading = task
		do {
			let manager = try await task.value
			self.manager = manager
			loading = nil
			logger.notice("Notes speech detector loaded")
			return manager
		} catch {
			loading = nil
			failedAt = Date()
			throw error
		}
	}
}
