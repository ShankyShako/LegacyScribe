import Foundation

/// What a dictation became by the time the user pressed Enter: the pasted text, then the version they
/// edited and sent. Captured from the focused field through Accessibility, never typed into history by
/// hand; an unchanged `sent` is a dictation the user was happy with as pasted.
public struct SentEdit: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var timestamp: Date
	/// The history entry the paste came from, when history is on.
	public var transcriptID: UUID?
	public var bundleID: String?
	public var appName: String?
	public var mode: RewriteMode?
	/// Speech-to-text output, before the rewrite.
	public var recognized: String
	/// What LegacyScribe pasted.
	public var pasted: String
	/// The same stretch of the field when Enter was pressed.
	public var sent: String

	public init(
		id: UUID = UUID(),
		timestamp: Date,
		transcriptID: UUID?,
		bundleID: String?,
		appName: String?,
		mode: RewriteMode?,
		recognized: String,
		pasted: String,
		sent: String
	) {
		self.id = id
		self.timestamp = timestamp
		self.transcriptID = transcriptID
		self.bundleID = bundleID
		self.appName = appName
		self.mode = mode
		self.recognized = recognized
		self.pasted = pasted
		self.sent = sent
	}

	public var wasEdited: Bool {
		pasted.trimmingCharacters(in: .whitespacesAndNewlines) != sent.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}

public struct SentEditLog: Codable, Equatable, Sendable {
	public var edits: [SentEdit] = []

	public init(edits: [SentEdit] = []) {
		self.edits = edits
	}
}

/// A paste waiting for Enter: the field before and right after the paste.
public struct PendingSentEdit: Equatable, Sendable {
	public var startedAt: Date
	public var transcriptID: UUID?
	public var bundleID: String
	public var appName: String?
	public var mode: RewriteMode?
	public var recognized: String
	public var pasted: String
	public var fieldBefore: String
	public var fieldAfterPaste: String

	/// After this long the paste is considered abandoned.
	public static let lifetime: TimeInterval = 15 * 60

	public init(
		startedAt: Date,
		transcriptID: UUID?,
		bundleID: String,
		appName: String?,
		mode: RewriteMode?,
		recognized: String,
		pasted: String,
		fieldBefore: String,
		fieldAfterPaste: String
	) {
		self.startedAt = startedAt
		self.transcriptID = transcriptID
		self.bundleID = bundleID
		self.appName = appName
		self.mode = mode
		self.recognized = recognized
		self.pasted = pasted
		self.fieldBefore = fieldBefore
		self.fieldAfterPaste = fieldAfterPaste
	}

	public func isExpired(at date: Date) -> Bool {
		date.timeIntervalSince(startedAt) > Self.lifetime
	}

	/// The sent version of the pasted stretch, given the field's text when Enter was pressed.
	public func sentEdit(finalField: String, at date: Date) -> SentEdit? {
		guard let sent = SentEditExtractor.editedSegment(
			before: fieldBefore,
			afterPaste: fieldAfterPaste,
			final: finalField
		) else { return nil }
		return SentEdit(
			timestamp: date,
			transcriptID: transcriptID,
			bundleID: bundleID,
			appName: appName,
			mode: mode,
			recognized: recognized,
			pasted: pasted,
			sent: sent
		)
	}
}

public enum SentEditExtractor {
	/// Finds the pasted stretch in the field's final text. The text around the paste (what the field held
	/// before it) must be unchanged; otherwise nil, because the edit can't be told apart from other changes.
	/// Nil also when the result is empty or implausibly larger than the paste.
	public static func editedSegment(before: String, afterPaste: String, final: String) -> String? {
		let b = Array(before), a = Array(afterPaste), f = Array(final)
		guard a != b else { return nil } // The paste never landed in this field.

		var prefix = 0
		while prefix < b.count, prefix < a.count, b[prefix] == a[prefix] { prefix += 1 }
		var suffix = 0
		while suffix < b.count - prefix, suffix < a.count - prefix,
		      b[b.count - 1 - suffix] == a[a.count - 1 - suffix] { suffix += 1 }

		guard prefix + suffix <= f.count,
		      f[..<prefix].elementsEqual(b[..<prefix]),
		      f[(f.count - suffix)...].elementsEqual(b[(b.count - suffix)...])
		else { return nil }

		let pastedLength = a.count - prefix - suffix
		let segment = String(f[prefix ..< (f.count - suffix)]).trimmingCharacters(in: .whitespacesAndNewlines)
		guard !segment.isEmpty, segment.count <= pastedLength * 3 + 200 else { return nil }
		return segment
	}
}
