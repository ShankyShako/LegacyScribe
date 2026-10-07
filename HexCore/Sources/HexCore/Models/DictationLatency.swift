import Foundation

/// Stage timestamps for one dictation, measured from hotkey release.
/// Filled in as the pipeline advances; `latency` turns it into per-stage durations.
public struct DictationTimeline: Equatable, Sendable {
	public var keyUp: ContinuousClock.Instant
	/// Recorder stopped and the audio file is finalized.
	public var captureStopped: ContinuousClock.Instant?
	/// Speech-to-text returned.
	public var transcribed: ContinuousClock.Instant?
	/// Word removals/remappings applied and history entry saved.
	public var postProcessed: ContinuousClock.Instant?
	/// Paste keystroke posted to the frontmost app.
	public var pasted: ContinuousClock.Instant?

	public init(keyUp: ContinuousClock.Instant) {
		self.keyUp = keyUp
	}

	/// Nil until every stage has been stamped.
	public func latency(audioSeconds: Double, engine: String) -> DictationLatency? {
		guard let captureStopped, let transcribed, let postProcessed, let pasted else { return nil }
		return DictationLatency(
			captureMs: (captureStopped - keyUp).milliseconds,
			transcribeMs: (transcribed - captureStopped).milliseconds,
			postProcessMs: (postProcessed - transcribed).milliseconds,
			pasteMs: (pasted - postProcessed).milliseconds,
			audioSeconds: audioSeconds,
			engine: engine
		)
	}
}

public struct DictationLatency: Equatable, Sendable, Codable {
	public var captureMs: Double
	public var transcribeMs: Double
	public var postProcessMs: Double
	public var pasteMs: Double
	public var audioSeconds: Double
	public var engine: String

	public init(captureMs: Double, transcribeMs: Double, postProcessMs: Double, pasteMs: Double, audioSeconds: Double, engine: String) {
		self.captureMs = captureMs
		self.transcribeMs = transcribeMs
		self.postProcessMs = postProcessMs
		self.pasteMs = pasteMs
		self.audioSeconds = audioSeconds
		self.engine = engine
	}

	/// Hotkey release → paste posted.
	public var totalMs: Double { captureMs + transcribeMs + postProcessMs + pasteMs }

	/// e.g. "412 ms (capture 12 · STT 300 · save 20 · paste 80) for 8.1 s audio"
	public var summary: String {
		func ms(_ value: Double) -> String { String(Int(value.rounded())) }
		return "\(ms(totalMs)) ms (capture \(ms(captureMs)) · STT \(ms(transcribeMs)) · save \(ms(postProcessMs)) · paste \(ms(pasteMs)))"
			+ " for \(String(format: "%.1f", audioSeconds)) s audio"
	}
}

extension Duration {
	var milliseconds: Double {
		Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
	}
}
