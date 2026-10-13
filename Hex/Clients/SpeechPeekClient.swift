import Dependencies
import DependenciesMacros
import Foundation
import HexCore

/// A quick look at what's being said while recording: Apple Speech (on-device, macOS hosts the model)
/// transcribes the start of the dictation so Legacy can show before the real engine runs.
@DependencyClient
struct SpeechPeekClient {
	/// False when Apple's English model isn't installed; peeking is skipped then.
	var isAvailable: @Sendable () async -> Bool = { false }
	/// The text of 16 kHz mono samples; nil when it couldn't be transcribed.
	var transcribe: @Sendable ([Float]) async -> String? = { _ in nil }
}

extension SpeechPeekClient: DependencyKey {
	static var liveValue: Self {
		Self(
			isAvailable: { await AppleSpeech.isInstalled() },
			transcribe: { samples in
				do {
					return try await AppleSpeech.transcribe(samples: samples)
				} catch {
					HexLog.transcription.error("Peek failed: \(error.localizedDescription, privacy: .public)")
					return nil
				}
			}
		)
	}

	static var testValue: Self { Self(isAvailable: { false }, transcribe: { _ in nil }) }
}

extension DependencyValues {
	var speechPeek: SpeechPeekClient {
		get { self[SpeechPeekClient.self] }
		set { self[SpeechPeekClient.self] = newValue }
	}
}
