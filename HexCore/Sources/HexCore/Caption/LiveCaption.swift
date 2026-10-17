import Foundation

/// One result from Apple's streaming recognizer, reduced to what the caption needs.
public struct CaptionResult: Equatable, Sendable {
	public var isFinal: Bool
	public var text: String
	/// Seconds of audio the result covers.
	public var start: Double
	public var end: Double

	public init(isFinal: Bool, text: String, start: Double, end: Double) {
		self.isFinal = isFinal
		self.text = text
		self.start = start
		self.end = end
	}
}

/// What the caption shows: words in order, the last one dimmed while it is still volatile.
public struct CaptionText: Equatable, Sendable {
	public var words: [String]
	public var dimLast: Bool

	public init(words: [String], dimLast: Bool) {
		self.words = words
		self.dimLast = dimLast
	}

	public var text: String { words.joined(separator: " ") }
	public var isEmpty: Bool { words.isEmpty }
}

/// The caption's state machine (rules from `lsbench live --stream`'s replay): finalized results append, the
/// newest volatile result replaces the previous one, and a final covering the volatile's start clears it.
public struct LiveCaption: Equatable, Sendable {
	/// The display keeps this many words; the view truncates at the head anyway, this caps layout on a long dictation.
	public static let tailWords = 80

	private var finalized: [String] = []
	private var volatile: CaptionResult?

	public init() {}

	public mutating func apply(_ result: CaptionResult) {
		let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
		if result.isFinal {
			if !trimmed.isEmpty { finalized.append(contentsOf: Self.split(trimmed)) }
			if let v = volatile, v.start < result.end - 0.01 { volatile = nil }
			// Keep only what the display can show.
			if finalized.count > Self.tailWords { finalized.removeFirst(finalized.count - Self.tailWords) }
		} else {
			volatile = result
		}
	}

	public var display: CaptionText {
		let tail = volatile.map { Self.split($0.text) } ?? []
		let words = Array((finalized + tail).suffix(Self.tailWords))
		return CaptionText(words: words, dimLast: !tail.isEmpty)
	}

	private static func split(_ text: String) -> [String] {
		text.split(whereSeparator: \.isWhitespace).map(String.init)
	}
}
