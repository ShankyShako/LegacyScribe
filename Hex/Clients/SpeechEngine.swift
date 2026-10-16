import Foundation
import HexCore

/// A speech-to-text engine the app can dictate with. `TranscriptionClientLive` hands a model name to the
/// engine that handles it; WhisperKit, the engine upstream Hex was built around, still lives inline there
/// and takes every name no engine claims.
protocol SpeechEngine: Sendable {
	func handles(_ model: String) -> Bool
	func isDownloaded(_ model: String) async -> Bool
	/// Downloads if needed and loads, so the next `transcribe` is warm.
	func prepare(_ model: String, progress: @escaping (Progress) -> Void) async throws
	func transcribe(_ audio: URL, model: String) async throws -> String
	func delete(_ model: String) async throws
	/// True when the engine is loaded as the talk key goes down and dropped after each dictation (it holds
	/// a lot of memory and reloads fast); false when it stays loaded.
	var loadsPerDictation: Bool { get }
	/// Drops the loaded model; called after each dictation for `loadsPerDictation` engines.
	func releaseMemory() async
}

extension SpeechEngine {
	var loadsPerDictation: Bool { false }
	func releaseMemory() async {}
}

/// Parakeet TDT through FluidAudio (Core ML). Stays loaded: its memory sits mostly outside the app.
struct ParakeetEngine: SpeechEngine {
	let client: ParakeetClient

	func handles(_ model: String) -> Bool {
		ParakeetModel(rawValue: model) != nil
	}

	func isDownloaded(_ model: String) async -> Bool {
		await client.isModelAvailable(model)
	}

	func prepare(_ model: String, progress: @escaping (Progress) -> Void) async throws {
		try await client.ensureLoaded(modelName: model, progress: progress)
	}

	func transcribe(_ audio: URL, model: String) async throws -> String {
		try await prepare(model) { _ in }
		// Parakeet drops speech in clips under a second; pad them.
		let clip = try ParakeetClipPreparer.ensureMinimumDuration(url: audio, logger: HexLog.parakeet)
		defer { clip.cleanup() }
		return try await client.transcribe(clip.url)
	}

	func delete(_ model: String) async throws {
		try await client.deleteCaches(modelName: model)
	}
}

/// Cohere Transcribe through MLX. ~1.9 GB while loaded, so it loads per dictation (CLAUDE.md).
struct CohereEngine: SpeechEngine {
	let client: CohereClient

	func handles(_ model: String) -> Bool {
		CohereModel(rawValue: model) != nil
	}

	func isDownloaded(_ model: String) async -> Bool {
		await client.isModelAvailable(model)
	}

	func prepare(_ model: String, progress: @escaping (Progress) -> Void) async throws {
		try await client.ensureLoaded(modelName: model, progress: progress)
	}

	func transcribe(_ audio: URL, model: String) async throws -> String {
		try await prepare(model) { _ in }
		return try await client.transcribeSpeech(audio, modelName: model)
	}

	func delete(_ model: String) async throws {
		try await client.deleteCaches(modelName: model)
	}

	var loadsPerDictation: Bool { true }

	func releaseMemory() async {
		await client.unload()
	}
}

/// Apple's SpeechAnalyzer (macOS 26). The model is a system asset macOS keeps loaded and shares, so there
/// is nothing to hold or drop here, and deleting is up to macOS.
struct AppleSpeechEngine: SpeechEngine {
	func handles(_ model: String) -> Bool {
		model == AppleSpeech.identifier
	}

	func isDownloaded(_: String) async -> Bool {
		await AppleSpeech.isInstalled()
	}

	func prepare(_: String, progress: @escaping (Progress) -> Void) async throws {
		// macOS downloads the model in its own daemon, out of reach of the app's URLProtocol backstop.
		if NetworkPolicy.isPrivate, !(await AppleSpeech.isInstalled()) {
			throw NetworkPolicy.Denied(url: nil)
		}
		let overall = Progress(totalUnitCount: 100)
		nonisolated(unsafe) let report = progress
		try await AppleSpeech.install { fraction in
			overall.completedUnitCount = Int64(fraction * 100)
			report(overall)
		}
	}

	func transcribe(_ audio: URL, model _: String) async throws -> String {
		try await AppleSpeech.transcribe(audio)
	}

	func delete(_: String) async throws {}
}
