import Foundation

/// What writes a notes session's notes.
public enum NotesWriter: String, Codable, CaseIterable, Equatable, Sendable {
	/// A downloaded model run in-process (`LocalLLMModel`).
	case onDevice
	/// Ollama on this Mac, through its native API.
	case ollama
}

public enum RecordingAudioBehavior: String, Codable, CaseIterable, Equatable, Sendable {
	case pauseMedia
	case mute
	case doNothing
}

/// User-configurable settings saved to disk.
public struct HexSettings: Codable, Equatable, Sendable {
	public static let defaultPasteLastTranscriptHotkey = HotKey(key: .v, modifiers: [.option, .shift])
	public static let baseSoundEffectsVolume: Double = HexCoreConstants.baseSoundEffectsVolume
	public static let defaultWordRemovals: [WordRemoval] = [
		.init(pattern: "uh+"),
		.init(pattern: "um+"),
		.init(pattern: "er+"),
		.init(pattern: "hm+")
	]

	/// A downloaded model on this Mac: works without an account, a key or another app. Until it's
	/// downloaded, dictations are pasted as recognized.
	public static let defaultRewritePrimary = RewriteEndpoint.preset(.onDevice)
	/// Off by default; a cloud key is the usual second choice.
	public static let defaultRewriteFallback = RewriteEndpoint.preset(.groq)

	public static var defaultPasteLastTranscriptHotkeyDescription: String {
		let modifiers = defaultPasteLastTranscriptHotkey.modifiers.sorted.map { $0.stringValue }.joined()
		let key = defaultPasteLastTranscriptHotkey.key?.toString ?? ""
		return modifiers + key
	}

	public var soundEffectsEnabled: Bool
	public var soundEffectsVolume: Double
	public var hotkey: HotKey
	public var openOnLogin: Bool
	public var showDockIcon: Bool
	public var selectedModel: String
	public var useClipboardPaste: Bool
	public var preventSystemSleep: Bool
	public var recordingAudioBehavior: RecordingAudioBehavior
	public var minimumKeyTime: Double
	public var copyToClipboard: Bool
	public var superFastModeEnabled: Bool
	public var useDoubleTapOnly: Bool
	public var doubleTapLockEnabled: Bool
	public var outputLanguage: String?
	public var selectedMicrophoneID: String?
	public var saveTranscriptionHistory: Bool
	public var maxHistoryEntries: Int?
	public var pasteLastTranscriptHotkey: HotKey?
	public var hasCompletedModelBootstrap: Bool
	public var hasCompletedStorageMigration: Bool
	public var wordRemovalsEnabled: Bool
	public var wordRemovals: [WordRemoval]
	public var wordRemappings: [WordRemapping]
	public var lowercaseTranscripts: Bool
	public var removePunctuation: Bool
	public var rewriteMode: RewriteMode
	/// Tried first. API keys live in the Keychain, not here.
	public var rewritePrimary: RewriteEndpoint
	/// Tried when the primary fails or times out; if this fails too, the raw transcript is pasted.
	public var rewriteFallback: RewriteEndpoint
	public var rewriteFallbackEnabled: Bool
	/// ⌃⌥1–4 switch the mode from any app.
	public var rewriteModeShortcutsEnabled: Bool
	/// Terms the LLM should spell exactly (names, products, jargon).
	public var vocabulary: [String]
	/// The user's own instructions per mode, keyed by `RewriteMode.rawValue`; a missing mode uses the built-in default.
	public var rewriteInstructions: [String: String]
	/// Prompt mode writes spoken notation as code ("slash handoff" → /handoff) and knows the user's skills.
	public var codeTalkEnabled: Bool
	/// Hold ⌃ and press ⌥ to cycle modes, like ⌘-Tab (`ModeCycler`).
	public var modeCyclerEnabled: Bool
	/// Prompt mode merges a dictation into the text already in the focused field (`FieldMerge`).
	public var mergeIntoFieldEnabled: Bool
	/// Names from the text around the cursor (`ContextTerms`) become spelling hints for the rewrite and the
	/// speech engine. Read through Accessibility when the talk key goes down.
	public var contextTermsEnabled: Bool
	/// Remember what each dictation became when Enter was pressed (`SentEdit`), read through Accessibility.
	public var captureSentEdits: Bool
	/// Fit each paste to the text around the cursor: case, closing period, spaces (`InsertionAdjuster`).
	public var matchSurroundingText: Bool
	/// `legacyscribe://start`, `toggle` and `notes/start` may turn the microphone on (`URLAction`). Off by
	/// default because any web page can open the URL; stop, cancel and mode changes always work.
	public var urlActionsEnabled: Bool
	/// A dictation that starts with "super" is an instruction: it edits the selection or writes at the cursor
	/// (`SuperTrigger`).
	public var superEnabled: Bool
	/// While recording, Apple Speech listens to the first seconds for "super" so the indicator shows it early.
	public var superEarlyDetection: Bool
	/// Times the "say 'super' first" hint was shown for a selection; it stops after `SuperTrigger.hintLimit`.
	public var superHintsShown: Int
	/// Model (on the primary endpoint) that answers the Practice tab's research question; it should be able
	/// to search the web, e.g. an OmniRoute search combo.
	public var practiceResearchModel: String
	/// What writes a notes session's notes. Both keep the transcript on this Mac.
	public var notesWriter: NotesWriter
	/// On-device model (`LocalLLMModel` repository) that writes notes when `notesWriter` is `.onDevice`.
	public var notesLocalModel: String
	/// Ollama's root URL for notes sessions (its own API, not `/v1`).
	public var notesOllamaURL: String
	/// Ollama model that writes notes when `notesWriter` is `.ollama`.
	public var notesModel: String
	/// Folder that also gets each session's notes as Markdown (an Obsidian vault, say); nil keeps them in the app only.
	public var notesExportFolder: String?
	/// Dictation records through Apple's voice processing, which keeps the voice nearest the microphone and
	/// lowers other voices and noise; the system's Voice Isolation mic mode applies on top.
	public var voiceIsolationEnabled: Bool
	/// The same for notes sessions (off by default: a meeting may need every voice in the room).
	public var voiceIsolationInNotes: Bool
	/// Dictation recordings older than this many days are deleted (the text stays); 0 keeps them forever.
	public var audioRetentionDays: Int
	/// No network at all (`NetworkPolicy`): only the on-device model rewrites, no update checks or downloads.
	public var privateMode: Bool
	/// How long a cancelled dictation's recording is kept for Undo (Esc, or a cancel mid-transcription); 0 deletes it at once.
	public var cancelUndoSeconds: Int

	private mutating func normalizeDoubleTapSettings() {
		if !doubleTapLockEnabled {
			useDoubleTapOnly = false
		}
	}

	public init(
		soundEffectsEnabled: Bool = true,
		soundEffectsVolume: Double = HexSettings.baseSoundEffectsVolume,
		hotkey: HotKey = .init(key: nil, modifiers: [.option.with(side: .right)]),
		openOnLogin: Bool = false,
		showDockIcon: Bool = true,
		selectedModel: String = ParakeetModel.multilingualV3.identifier,
		useClipboardPaste: Bool = true,
		preventSystemSleep: Bool = true,
		recordingAudioBehavior: RecordingAudioBehavior = .doNothing,
		minimumKeyTime: Double = HexCoreConstants.defaultMinimumKeyTime,
		copyToClipboard: Bool = false,
		superFastModeEnabled: Bool = false,
		useDoubleTapOnly: Bool = false,
		doubleTapLockEnabled: Bool = true,
		outputLanguage: String? = nil,
		selectedMicrophoneID: String? = nil,
		saveTranscriptionHistory: Bool = true,
		maxHistoryEntries: Int? = nil,
		pasteLastTranscriptHotkey: HotKey? = HexSettings.defaultPasteLastTranscriptHotkey,
		hasCompletedModelBootstrap: Bool = false,
		hasCompletedStorageMigration: Bool = false,
		wordRemovalsEnabled: Bool = false,
		wordRemovals: [WordRemoval] = HexSettings.defaultWordRemovals,
		wordRemappings: [WordRemapping] = [],
		lowercaseTranscripts: Bool = false,
		removePunctuation: Bool = false,
		rewriteMode: RewriteMode = .clean,
		rewritePrimary: RewriteEndpoint = HexSettings.defaultRewritePrimary,
		rewriteFallback: RewriteEndpoint = HexSettings.defaultRewriteFallback,
		rewriteFallbackEnabled: Bool = false,
		rewriteModeShortcutsEnabled: Bool = true,
		vocabulary: [String] = [],
		rewriteInstructions: [String: String] = [:],
		codeTalkEnabled: Bool = true,
		modeCyclerEnabled: Bool = true,
		mergeIntoFieldEnabled: Bool = true,
		contextTermsEnabled: Bool = true,
		captureSentEdits: Bool = true,
		matchSurroundingText: Bool = true,
		urlActionsEnabled: Bool = false,
		superEnabled: Bool = true,
		superEarlyDetection: Bool = true,
		superHintsShown: Int = 0,
		practiceResearchModel: String = "wp-search",
		notesWriter: NotesWriter = .onDevice,
		notesLocalModel: String = LocalLLMModel.recommended.repository,
		notesOllamaURL: String = "http://localhost:11434",
		notesModel: String = "qwen3:8b",
		notesExportFolder: String? = nil,
		voiceIsolationEnabled: Bool = false,
		voiceIsolationInNotes: Bool = false,
		audioRetentionDays: Int = AudioRetention.defaultDays,
		privateMode: Bool = false,
		cancelUndoSeconds: Int = 30
	) {
		self.soundEffectsEnabled = soundEffectsEnabled
		self.soundEffectsVolume = soundEffectsVolume
		self.hotkey = hotkey
		self.openOnLogin = openOnLogin
		self.showDockIcon = showDockIcon
		self.selectedModel = selectedModel
		self.useClipboardPaste = useClipboardPaste
		self.preventSystemSleep = preventSystemSleep
		self.recordingAudioBehavior = recordingAudioBehavior
		self.minimumKeyTime = minimumKeyTime
		self.copyToClipboard = copyToClipboard
		self.superFastModeEnabled = superFastModeEnabled
		self.useDoubleTapOnly = useDoubleTapOnly
		self.doubleTapLockEnabled = doubleTapLockEnabled
		self.outputLanguage = outputLanguage
		self.selectedMicrophoneID = selectedMicrophoneID
		self.saveTranscriptionHistory = saveTranscriptionHistory
		self.maxHistoryEntries = maxHistoryEntries
		self.pasteLastTranscriptHotkey = pasteLastTranscriptHotkey
		self.hasCompletedModelBootstrap = hasCompletedModelBootstrap
		self.hasCompletedStorageMigration = hasCompletedStorageMigration
		self.wordRemovalsEnabled = wordRemovalsEnabled
		self.wordRemovals = wordRemovals
		self.wordRemappings = wordRemappings
		self.lowercaseTranscripts = lowercaseTranscripts
		self.removePunctuation = removePunctuation
		self.rewriteMode = rewriteMode
		self.rewritePrimary = rewritePrimary
		self.rewriteFallback = rewriteFallback
		self.rewriteFallbackEnabled = rewriteFallbackEnabled
		self.rewriteModeShortcutsEnabled = rewriteModeShortcutsEnabled
		self.vocabulary = vocabulary
		self.rewriteInstructions = rewriteInstructions
		self.codeTalkEnabled = codeTalkEnabled
		self.modeCyclerEnabled = modeCyclerEnabled
		self.mergeIntoFieldEnabled = mergeIntoFieldEnabled
		self.contextTermsEnabled = contextTermsEnabled
		self.captureSentEdits = captureSentEdits
		self.matchSurroundingText = matchSurroundingText
		self.urlActionsEnabled = urlActionsEnabled
		self.superEnabled = superEnabled
		self.superEarlyDetection = superEarlyDetection
		self.superHintsShown = superHintsShown
		self.practiceResearchModel = practiceResearchModel
		self.notesWriter = notesWriter
		self.notesLocalModel = notesLocalModel
		self.notesOllamaURL = notesOllamaURL
		self.notesModel = notesModel
		self.notesExportFolder = notesExportFolder
		self.voiceIsolationEnabled = voiceIsolationEnabled
		self.voiceIsolationInNotes = voiceIsolationInNotes
		self.audioRetentionDays = audioRetentionDays
		self.privateMode = privateMode
		self.cancelUndoSeconds = cancelUndoSeconds
		normalizeDoubleTapSettings()
	}

	public init(from decoder: Decoder) throws {
		self.init()
		let container = try decoder.container(keyedBy: HexSettingKey.self)
		for field in HexSettingsSchema.fields {
			try field.decode(into: &self, from: container)
		}
		normalizeDoubleTapSettings()
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: HexSettingKey.self)
		for field in HexSettingsSchema.fields {
			try field.encode(self, into: &container)
		}
	}
}

// MARK: - Schema

private enum HexSettingKey: String, CodingKey, CaseIterable {
	case soundEffectsEnabled
	case soundEffectsVolume
	case hotkey
	case openOnLogin
	case showDockIcon
	case selectedModel
	case useClipboardPaste
	case preventSystemSleep
	case recordingAudioBehavior
	case pauseMediaOnRecord // Legacy
	case minimumKeyTime
	case copyToClipboard
	case superFastModeEnabled
	case useDoubleTapOnly
	case doubleTapLockEnabled
	case outputLanguage
	case selectedMicrophoneID
	case saveTranscriptionHistory
	case maxHistoryEntries
	case pasteLastTranscriptHotkey
	case hasCompletedModelBootstrap
	case hasCompletedStorageMigration
	case wordRemovalsEnabled
	case wordRemovals
	case wordRemappings
	case lowercaseTranscripts
	case removePunctuation
	case rewriteMode
	case rewritePrimary
	case rewriteFallback
	case rewriteFallbackEnabled
	case rewriteModeShortcutsEnabled
	case vocabulary
	case rewriteInstructions
	case codeTalkEnabled
	case modeCyclerEnabled
	case mergeIntoFieldEnabled
	case contextTermsEnabled
	case captureSentEdits
	case matchSurroundingText
	case urlActionsEnabled
	case superEnabled
	case superEarlyDetection
	case superHintsShown
	case practiceResearchModel
	case notesWriter
	case notesLocalModel
	case notesOllamaURL
	case notesModel
	case notesExportFolder
	case voiceIsolationEnabled
	case voiceIsolationInNotes
	case audioRetentionDays
	case privateMode
	case cancelUndoSeconds
}

private struct SettingsField<Value: Codable & Sendable> {
	let key: HexSettingKey
	let keyPath: WritableKeyPath<HexSettings, Value>
	let defaultValue: Value
	let decodeStrategy: (KeyedDecodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Value
	let encodeStrategy: (inout KeyedEncodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Void

	init(
		_ key: HexSettingKey,
		keyPath: WritableKeyPath<HexSettings, Value>,
		default defaultValue: Value,
		decode: ((KeyedDecodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Value)? = nil,
		encode: ((inout KeyedEncodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Void)? = nil
	) {
		self.key = key
		self.keyPath = keyPath
		self.defaultValue = defaultValue
		self.decodeStrategy = decode ?? { container, key, defaultValue in
			try container.decodeIfPresent(Value.self, forKey: key) ?? defaultValue
		}
		self.encodeStrategy = encode ?? { container, key, value in
			try container.encode(value, forKey: key)
		}
	}

	func eraseToAny() -> AnySettingsField {
		AnySettingsField(
			key: key,
			decode: { container, settings in
				let value = try decodeStrategy(container, key, defaultValue)
				settings[keyPath: keyPath] = value
			},
			encode: { settings, container in
				let value = settings[keyPath: keyPath]
				try encodeStrategy(&container, key, value)
			}
		)
	}
}

private struct AnySettingsField {
	let key: HexSettingKey
	let decode: (KeyedDecodingContainer<HexSettingKey>, inout HexSettings) throws -> Void
	let encode: (HexSettings, inout KeyedEncodingContainer<HexSettingKey>) throws -> Void

	func decode(into settings: inout HexSettings, from container: KeyedDecodingContainer<HexSettingKey>) throws {
		try decode(container, &settings)
	}

	func encode(_ settings: HexSettings, into container: inout KeyedEncodingContainer<HexSettingKey>) throws {
		try encode(settings, &container)
	}
}

private enum HexSettingsSchema {
	static let defaults = HexSettings()

	nonisolated(unsafe) static let fields: [AnySettingsField] = [
		SettingsField(.soundEffectsEnabled, keyPath: \.soundEffectsEnabled, default: defaults.soundEffectsEnabled).eraseToAny(),
		SettingsField(.soundEffectsVolume, keyPath: \.soundEffectsVolume, default: defaults.soundEffectsVolume).eraseToAny(),
		SettingsField(.hotkey, keyPath: \.hotkey, default: defaults.hotkey).eraseToAny(),
		SettingsField(.openOnLogin, keyPath: \.openOnLogin, default: defaults.openOnLogin).eraseToAny(),
		SettingsField(.showDockIcon, keyPath: \.showDockIcon, default: defaults.showDockIcon).eraseToAny(),
		SettingsField(.selectedModel, keyPath: \.selectedModel, default: defaults.selectedModel).eraseToAny(),
		SettingsField(.useClipboardPaste, keyPath: \.useClipboardPaste, default: defaults.useClipboardPaste).eraseToAny(),
		SettingsField(.preventSystemSleep, keyPath: \.preventSystemSleep, default: defaults.preventSystemSleep).eraseToAny(),
		SettingsField(
			.recordingAudioBehavior,
			keyPath: \.recordingAudioBehavior,
			default: defaults.recordingAudioBehavior,
			decode: { container, key, defaultValue in
				if let value = try container.decodeIfPresent(RecordingAudioBehavior.self, forKey: key) {
					return value
				}
				if let legacyPause = try container.decodeIfPresent(Bool.self, forKey: .pauseMediaOnRecord) {
					return legacyPause ? .pauseMedia : .doNothing
				}
				return defaultValue
			}
		).eraseToAny(),
		SettingsField(.minimumKeyTime, keyPath: \.minimumKeyTime, default: defaults.minimumKeyTime).eraseToAny(),
		SettingsField(.copyToClipboard, keyPath: \.copyToClipboard, default: defaults.copyToClipboard).eraseToAny(),
		SettingsField(.superFastModeEnabled, keyPath: \.superFastModeEnabled, default: defaults.superFastModeEnabled).eraseToAny(),
		SettingsField(.useDoubleTapOnly, keyPath: \.useDoubleTapOnly, default: defaults.useDoubleTapOnly).eraseToAny(),
		SettingsField(.doubleTapLockEnabled, keyPath: \.doubleTapLockEnabled, default: defaults.doubleTapLockEnabled).eraseToAny(),
		SettingsField(
			.outputLanguage,
			keyPath: \.outputLanguage,
			default: defaults.outputLanguage,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(
			.selectedMicrophoneID,
			keyPath: \.selectedMicrophoneID,
			default: defaults.selectedMicrophoneID,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(.saveTranscriptionHistory, keyPath: \.saveTranscriptionHistory, default: defaults.saveTranscriptionHistory).eraseToAny(),
		SettingsField(
			.maxHistoryEntries,
			keyPath: \.maxHistoryEntries,
			default: defaults.maxHistoryEntries,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(
			.pasteLastTranscriptHotkey,
			keyPath: \.pasteLastTranscriptHotkey,
			default: defaults.pasteLastTranscriptHotkey,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(.hasCompletedModelBootstrap, keyPath: \.hasCompletedModelBootstrap, default: defaults.hasCompletedModelBootstrap).eraseToAny(),
		SettingsField(.hasCompletedStorageMigration, keyPath: \.hasCompletedStorageMigration, default: defaults.hasCompletedStorageMigration).eraseToAny(),
		SettingsField(.wordRemovalsEnabled, keyPath: \.wordRemovalsEnabled, default: defaults.wordRemovalsEnabled).eraseToAny(),
		SettingsField(
			.wordRemovals,
			keyPath: \.wordRemovals,
			default: defaults.wordRemovals
		).eraseToAny(),
		SettingsField(
			.wordRemappings,
			keyPath: \.wordRemappings,
			default: defaults.wordRemappings
		).eraseToAny(),
		SettingsField(.lowercaseTranscripts, keyPath: \.lowercaseTranscripts, default: defaults.lowercaseTranscripts).eraseToAny(),
		SettingsField(.removePunctuation, keyPath: \.removePunctuation, default: defaults.removePunctuation).eraseToAny(),
		SettingsField(.rewriteMode, keyPath: \.rewriteMode, default: defaults.rewriteMode).eraseToAny(),
		SettingsField(.rewritePrimary, keyPath: \.rewritePrimary, default: defaults.rewritePrimary).eraseToAny(),
		SettingsField(.rewriteFallback, keyPath: \.rewriteFallback, default: defaults.rewriteFallback).eraseToAny(),
		SettingsField(.rewriteFallbackEnabled, keyPath: \.rewriteFallbackEnabled, default: defaults.rewriteFallbackEnabled).eraseToAny(),
		SettingsField(.rewriteModeShortcutsEnabled, keyPath: \.rewriteModeShortcutsEnabled, default: defaults.rewriteModeShortcutsEnabled).eraseToAny(),
		SettingsField(.vocabulary, keyPath: \.vocabulary, default: defaults.vocabulary).eraseToAny(),
		SettingsField(.rewriteInstructions, keyPath: \.rewriteInstructions, default: defaults.rewriteInstructions).eraseToAny(),
		SettingsField(.codeTalkEnabled, keyPath: \.codeTalkEnabled, default: defaults.codeTalkEnabled).eraseToAny(),
		SettingsField(.modeCyclerEnabled, keyPath: \.modeCyclerEnabled, default: defaults.modeCyclerEnabled).eraseToAny(),
		SettingsField(.mergeIntoFieldEnabled, keyPath: \.mergeIntoFieldEnabled, default: defaults.mergeIntoFieldEnabled).eraseToAny(),
		SettingsField(.contextTermsEnabled, keyPath: \.contextTermsEnabled, default: defaults.contextTermsEnabled).eraseToAny(),
		SettingsField(.captureSentEdits, keyPath: \.captureSentEdits, default: defaults.captureSentEdits).eraseToAny(),
		SettingsField(.matchSurroundingText, keyPath: \.matchSurroundingText, default: defaults.matchSurroundingText).eraseToAny(),
		SettingsField(.urlActionsEnabled, keyPath: \.urlActionsEnabled, default: defaults.urlActionsEnabled).eraseToAny(),
		SettingsField(.superEnabled, keyPath: \.superEnabled, default: defaults.superEnabled).eraseToAny(),
		SettingsField(.superEarlyDetection, keyPath: \.superEarlyDetection, default: defaults.superEarlyDetection).eraseToAny(),
		SettingsField(.superHintsShown, keyPath: \.superHintsShown, default: defaults.superHintsShown).eraseToAny(),
		SettingsField(.practiceResearchModel, keyPath: \.practiceResearchModel, default: defaults.practiceResearchModel).eraseToAny(),
		SettingsField(
			.notesWriter,
			keyPath: \.notesWriter,
			default: defaults.notesWriter,
			decode: { container, key, defaultValue in
				if let value = try? container.decodeIfPresent(NotesWriter.self, forKey: key) { return value }
				// Settings saved before the on-device writer existed wrote notes with Ollama.
				return container.contains(.notesModel) ? .ollama : defaultValue
			}
		).eraseToAny(),
		SettingsField(.notesLocalModel, keyPath: \.notesLocalModel, default: defaults.notesLocalModel).eraseToAny(),
		SettingsField(.notesOllamaURL, keyPath: \.notesOllamaURL, default: defaults.notesOllamaURL).eraseToAny(),
		SettingsField(.notesModel, keyPath: \.notesModel, default: defaults.notesModel).eraseToAny(),
		SettingsField(
			.notesExportFolder,
			keyPath: \.notesExportFolder,
			default: defaults.notesExportFolder,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(.voiceIsolationEnabled, keyPath: \.voiceIsolationEnabled, default: defaults.voiceIsolationEnabled).eraseToAny(),
		SettingsField(.voiceIsolationInNotes, keyPath: \.voiceIsolationInNotes, default: defaults.voiceIsolationInNotes).eraseToAny(),
		SettingsField(.audioRetentionDays, keyPath: \.audioRetentionDays, default: defaults.audioRetentionDays).eraseToAny(),
		SettingsField(.privateMode, keyPath: \.privateMode, default: defaults.privateMode).eraseToAny(),
		SettingsField(.cancelUndoSeconds, keyPath: \.cancelUndoSeconds, default: defaults.cancelUndoSeconds).eraseToAny()
	]
}

extension HexSettings {
	/// The user's instructions for `mode`, or nil to use the built-in default.
	public func customInstructions(for mode: RewriteMode) -> String? {
		guard let text = rewriteInstructions[mode.rawValue],
		      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
		return text
	}

	/// Stores `text` for `mode`; blank text or the built-in default clears the override,
	/// so later improvements to the default still reach the user.
	public mutating func setCustomInstructions(_ text: String?, for mode: RewriteMode) {
		let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		if trimmed.isEmpty || trimmed == RewritePromptBuilder.taskInstructions(for: mode) {
			rewriteInstructions[mode.rawValue] = nil
		} else {
			rewriteInstructions[mode.rawValue] = text
		}
	}
}
