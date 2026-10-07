import Foundation

public struct Transcript: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var text: String
    public var audioPath: URL
    public var duration: TimeInterval
    public var sourceAppBundleID: String?
    public var sourceAppName: String?
    /// Speech-to-text output before the LLM rewrite; nil when the text wasn't rewritten.
    public var rawText: String?
    /// The mode that rewrote `text`; nil for raw transcripts.
    public var rewriteMode: RewriteMode?
    /// Model that produced `text`.
    public var rewrittenBy: String?
    /// Endpoints that failed before the rewrite succeeded or the raw transcript was pasted.
    public var rewriteFailures: [String]?
    public var latency: DictationLatency?
    
    public init(
        id: UUID = UUID(),
        timestamp: Date,
        text: String,
        audioPath: URL,
        duration: TimeInterval,
        sourceAppBundleID: String? = nil,
        sourceAppName: String? = nil,
        rawText: String? = nil,
        rewriteMode: RewriteMode? = nil,
        rewrittenBy: String? = nil,
        rewriteFailures: [String]? = nil,
        latency: DictationLatency? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.audioPath = audioPath
        self.duration = duration
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
        self.rawText = rawText
        self.rewriteMode = rewriteMode
        self.rewrittenBy = rewrittenBy
        self.rewriteFailures = rewriteFailures
        self.latency = latency
    }
}

public struct TranscriptionHistory: Codable, Equatable, Sendable {
    public var history: [Transcript] = []
    
    public init(history: [Transcript] = []) {
        self.history = history
    }
}
