import Foundation

/// Stage timestamps for one dictation, measured from hotkey release.
/// Filled in as the pipeline advances; `latency` turns it into per-stage durations.
public struct DictationTimeline: Equatable, Sendable {
	public var keyUp: ContinuousClock.Instant
	/// Recorder stopped and the audio file is finalized.
	public var captureStopped: ContinuousClock.Instant?
	/// Speech-to-text returned.
	public var transcribed: ContinuousClock.Instant?
	/// LLM rewrite returned (or failed). Nil when the mode skips the LLM.
	public var rewritten: ContinuousClock.Instant?
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
			rewriteMs: rewritten.map { ($0 - transcribed).milliseconds } ?? 0,
			postProcessMs: (postProcessed - (rewritten ?? transcribed)).milliseconds,
			pasteMs: (pasted - postProcessed).milliseconds,
			audioSeconds: audioSeconds,
			engine: engine
		)
	}
}

public struct DictationLatency: Equatable, Sendable, Codable {
	public var captureMs: Double
	public var transcribeMs: Double
	/// Zero when no LLM rewrite ran.
	public var rewriteMs: Double
	public var postProcessMs: Double
	public var pasteMs: Double
	public var audioSeconds: Double
	public var engine: String

	public init(captureMs: Double, transcribeMs: Double, rewriteMs: Double = 0, postProcessMs: Double, pasteMs: Double, audioSeconds: Double, engine: String) {
		self.captureMs = captureMs
		self.transcribeMs = transcribeMs
		self.rewriteMs = rewriteMs
		self.postProcessMs = postProcessMs
		self.pasteMs = pasteMs
		self.audioSeconds = audioSeconds
		self.engine = engine
	}

	/// Hotkey release → paste posted.
	public var totalMs: Double { captureMs + transcribeMs + rewriteMs + postProcessMs + pasteMs }

	/// e.g. "412 ms (capture 12 · STT 300 · save 20 · paste 80) for 8.1 s audio";
	/// an "LLM n" stage appears after STT when a rewrite ran.
	public var summary: String {
		func ms(_ value: Double) -> String { String(Int(value.rounded())) }
		let llm = rewriteMs > 0 ? " · LLM \(ms(rewriteMs))" : ""
		return "\(ms(totalMs)) ms (capture \(ms(captureMs)) · STT \(ms(transcribeMs))\(llm) · save \(ms(postProcessMs)) · paste \(ms(pasteMs)))"
			+ " for \(String(format: "%.1f", audioSeconds)) s audio"
	}
}

extension Duration {
	var milliseconds: Double {
		Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
	}
}
