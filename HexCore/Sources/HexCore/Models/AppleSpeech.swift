import AVFoundation
import Foundation
import Speech

/// Apple's on-device speech-to-text (SpeechAnalyzer + SpeechTranscriber, macOS 26), as a dictation engine.
/// Its English model is a system asset: macOS downloads it once (outside the app's process, so it works in
/// Private mode only if it's already installed) and keeps it out of the app's own models folder.
@available(macOS 26.0, *)
public enum AppleSpeech {
	/// The model name the app selects this engine by.
	public static let identifier = "apple-speech-analyzer-en"

	static let locale = Locale(identifier: "en-US")

	static func makeTranscriber() -> SpeechTranscriber {
		SpeechTranscriber(locale: locale, preset: .transcription)
	}

	public static func isInstalled() async -> Bool {
		// Not `AssetInventory.status`: it said `.supported` (and asked for an install) on a Mac whose en-US model
		// transcribed fine, so Legacy's early look never ran (2026-10-14).
		let wanted = locale.identifier(.bcp47)
		return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == wanted }
	}

	/// Downloads the English model if macOS doesn't have it yet; `progress` goes from 0 to 1.
	public static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
		guard let request = try await AssetInventory.assetInstallationRequest(supporting: [makeTranscriber()]) else {
			progress(1)
			return
		}
		let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { reported, _ in
			progress(reported.fractionCompleted)
		}
		defer { observation.invalidate() }
		try await request.downloadAndInstall()
		progress(1)
	}

	/// The text of the recording at `url`, final results only.
	public static func transcribe(_ url: URL) async throws -> String {
		let transcriber = makeTranscriber()
		let analyzer = SpeechAnalyzer(modules: [transcriber])
		let file = try AVAudioFile(forReading: url)
		let collector = Task {
			var pieces: [String] = []
			for try await result in transcriber.results {
				pieces.append(String(result.text.characters))
			}
			return pieces
		}
		if let end = try await analyzer.analyzeSequence(from: file) {
			try await analyzer.finalizeAndFinish(through: end)
		} else {
			await analyzer.cancelAndFinishNow()
		}
		return joined(try await collector.value)
	}

	/// The text of 16 kHz mono samples (the start of a recording in progress), final results only.
	public static func transcribe(samples: [Float], sampleRate: Double = 16_000) async throws -> String {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("peek-\(UUID().uuidString).wav")
		defer { try? FileManager.default.removeItem(at: url) }
		guard !samples.isEmpty, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
		      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
		else { return "" }
		buffer.frameLength = AVAudioFrameCount(samples.count)
		samples.withUnsafeBufferPointer { source in
			buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
		}
		do {
			let file = try AVAudioFile(forWriting: url, settings: format.settings)
			try file.write(from: buffer)
		}
		return try await transcribe(url)
	}

	/// Results arrive in pieces that may or may not carry their own spacing.
	static func joined(_ pieces: [String]) -> String {
		pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
			.joined(separator: " ")
	}
}
