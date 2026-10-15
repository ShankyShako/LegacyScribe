import AVFoundation
import AppKit
import ComposableArchitecture
import CoreAudio
import Dependencies
import HexCore
import IdentifiedCollections
import Sauce
import ServiceManagement
import SwiftUI

private let settingsLogger = HexLog.settings
private typealias SettingsAudioPropertyListenerBlock = @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void

private enum HotKeyCaptureTarget {
  case recording
  case pasteLastTranscript
}

extension SharedReaderKey
  where Self == InMemoryKey<Bool>.Default
{
  static var isSettingHotKey: Self {
    Self[.inMemory("isSettingHotKey"), default: false]
  }
  
  static var isSettingPasteLastTranscriptHotkey: Self {
    Self[.inMemory("isSettingPasteLastTranscriptHotkey"), default: false]
  }

  static var isRemappingScratchpadFocused: Self {
    Self[.inMemory("isRemappingScratchpadFocused"), default: false]
  }
}

// MARK: - Settings Feature

@Reducer
struct SettingsFeature {
  @ObservableState
  struct State {
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isSettingHotKey) var isSettingHotKey: Bool = false
    @Shared(.isSettingPasteLastTranscriptHotkey) var isSettingPasteLastTranscriptHotkey: Bool = false
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
    @Shared(.hotkeyPermissionState) var hotkeyPermissionState: HotkeyPermissionState

    var languages: IdentifiedArrayOf<Language> = []
    var currentModifiers: Modifiers = .init(modifiers: [])
    var currentPasteLastModifiers: Modifiers = .init(modifiers: [])
    var remappingScratchpadText: String = ""
    
    // Available microphones
    var availableInputDevices: [AudioInputDevice] = []
    var defaultInputDeviceName: String?

    // Model Management
    var modelDownload = ModelDownloadFeature.State()
    var shouldFlashModelSection = false

    // LLM rewrite endpoints; API keys mirror the Keychain, keyed by account (one per hosted provider).
    var rewriteAPIKeys: [String: String] = [:]
    var rewriteModelOptions: [RewriteEndpointRole: [String]] = [:]
    var rewriteStatus: [RewriteEndpointRole: RewriteEndpointStatus] = [:]

    // On-device models: which are on disk, and download progress (0…1) for those downloading.
    var localModelsDownloaded: Set<LocalLLMModel> = []
    var localModelProgress: [LocalLLMModel: Double] = [:]
    var localModelError: String?

    func apiKey(for role: RewriteEndpointRole) -> String {
      rewriteAPIKeys[hexSettings.endpoint(for: role).keychainAccount(role)] ?? ""
    }

    /// The slot can rewrite right now: its model is downloaded, or its key is in.
    func isRewriteReady(_ role: RewriteEndpointRole) -> Bool {
      let endpoint = hexSettings.endpoint(for: role)
      switch endpoint.provider {
      case .onDevice:
        return localModelsDownloaded.contains { $0.repository == endpoint.model }
      default:
        let hasKey = !apiKey(for: role).trimmingCharacters(in: .whitespaces).isEmpty
        return endpoint.isConfigured && (hasKey || !endpoint.provider.needsAPIKey)
      }
    }

  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)

    // Existing
    case task
    case startSettingHotKey
    case startSettingPasteLastTranscriptHotkey
    case clearPasteLastTranscriptHotkey
    case keyEvent(KeyEvent)
    case toggleOpenOnLogin(Bool)
    case toggleShowDockIcon(Bool)
    case togglePreventSystemSleep(Bool)
    case setRecordingAudioBehavior(RecordingAudioBehavior)
    case toggleSuperFastMode(Bool)
    case setUseClipboardPaste(Bool)
    case setCopyToClipboard(Bool)
    case setDoubleTapLockEnabled(Bool)
    case setUseDoubleTapOnly(Bool)
    case setMinimumKeyTime(Double)
    case setOutputLanguage(String?)
    case setSelectedMicrophoneID(String?)
    case setSoundEffectsEnabled(Bool)
    case setSoundEffectsVolume(Double)

    // Permission delegation (forwarded to AppFeature)
    case requestMicrophone
    case requestAccessibility
    case requestInputMonitoring

    // Microphone selection
    case loadAvailableInputDevices
    case availableInputDevicesLoaded([AudioInputDevice], String?)

    // Model Management
    case modelDownload(ModelDownloadFeature.Action)
    
    // History Management
    case toggleSaveTranscriptionHistory(Bool)
    case setMaxHistoryEntries(Int?)
    case setAudioRetentionDays(Int)
    case setCancelUndoSeconds(Int)
    case setPrivateMode(Bool)

    // Modifier configuration
    case setModifierSide(Modifier.Kind, Modifier.Side)

    // Word remappings
    case setWordRemovalsEnabled(Bool)
    case addWordRemoval
    case updateWordRemoval(WordRemoval)
    case removeWordRemoval(UUID)
    case addWordRemapping
    case updateWordRemapping(WordRemapping)
    case removeWordRemapping(UUID)
    case setRemappingScratchpadFocused(Bool)
    case setLowercaseTranscripts(Bool)
    case setRemovePunctuation(Bool)

    // LLM rewrite
    case setRewriteMode(RewriteMode)
    case setRewriteEndpoint(RewriteEndpointRole, RewriteEndpoint)
    case setRewriteFallbackEnabled(Bool)
    case setRewriteModeShortcutsEnabled(Bool)
    case setCodeTalkEnabled(Bool)
    case setModeCyclerEnabled(Bool)
    case setMergeIntoFieldEnabled(Bool)
    case setContextTermsEnabled(Bool)
    case setCaptureSentEdits(Bool)
    case setMatchSurroundingText(Bool)
    case setSuperEnabled(Bool)
    case setSuperEarlyDetection(Bool)
    case setURLActionsEnabled(Bool)
    case setVocabulary([String])
    /// Nil or the default text restores the built-in instructions.
    case setRewriteInstructions(RewriteMode, String?)
    case setRewriteAPIKey(RewriteEndpointRole, String)
    /// Switches the slot to the provider's defaults, keeping an address typed for the same provider.
    case setRewriteProvider(RewriteEndpointRole, RewriteProvider)
    case loadRewriteModels(RewriteEndpointRole)
    case rewriteModelsLoaded(RewriteEndpointRole, [String])
    /// Lists the provider's models, picks a fast one if the current model isn't offered, then runs a test rewrite.
    case connectRewriteEndpoint(RewriteEndpointRole)
    case testRewriteEndpoint(RewriteEndpointRole)
    case rewriteStatusChanged(RewriteEndpointRole, RewriteEndpointStatus)

    // On-device models
    case refreshLocalModels
    case downloadLocalModel(LocalLLMModel)
    case localModelProgress(LocalLLMModel, Double)
    case localModelDownloadFinished(LocalLLMModel, error: String?)
    case cancelLocalModelDownload(LocalLLMModel)
    case deleteLocalModel(LocalLLMModel)

    // Voice isolation
    case setVoiceIsolationEnabled(Bool)
    case setVoiceIsolationInNotes(Bool)
    case showMicrophoneModes
  }

  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.soundEffects) var soundEffects
  @Dependency(\.transcriptPersistence) var transcriptPersistence
  @Dependency(\.rewrite) var rewrite
  @Dependency(\.keychain) var keychain
  @Dependency(\.localLLM) var localLLM

  private func deleteAudioEffect(for transcripts: [Transcript]) -> Effect<Action> {
    .run { [transcriptPersistence] _ in
      for transcript in transcripts {
        try? await transcriptPersistence.deleteAudio(transcript)
      }
    }
  }

  private func beginCapture(_ target: HotKeyCaptureTarget, state: inout State) {
    switch target {
    case .recording:
      state.$isSettingHotKey.withLock { $0 = true }
      state.currentModifiers = .init(modifiers: [])
    case .pasteLastTranscript:
      state.$isSettingPasteLastTranscriptHotkey.withLock { $0 = true }
      state.currentPasteLastModifiers = .init(modifiers: [])
    }
  }

  private func endCapture(_ target: HotKeyCaptureTarget, state: inout State) {
    switch target {
    case .recording:
      state.$isSettingHotKey.withLock { $0 = false }
      state.currentModifiers = .init(modifiers: [])
    case .pasteLastTranscript:
      state.$isSettingPasteLastTranscriptHotkey.withLock { $0 = false }
      state.currentPasteLastModifiers = .init(modifiers: [])
    }
  }

  private func captureModifiers(for target: HotKeyCaptureTarget, state: State) -> Modifiers {
    switch target {
    case .recording:
      state.currentModifiers
    case .pasteLastTranscript:
      state.currentPasteLastModifiers
    }
  }

  private func updateCaptureModifiers(_ modifiers: Modifiers, for target: HotKeyCaptureTarget, state: inout State) {
    switch target {
    case .recording:
      state.currentModifiers = modifiers
    case .pasteLastTranscript:
      state.currentPasteLastModifiers = modifiers
    }
  }

  private func applyCapturedHotKey(key: Key?, modifiers: Modifiers, for target: HotKeyCaptureTarget, state: inout State) {
    switch target {
    case .recording:
      state.$hexSettings.withLock {
        $0.hotkey.key = key
        $0.hotkey.modifiers = modifiers.erasingSides()
      }
    case .pasteLastTranscript:
      guard let key else { return }
      state.$hexSettings.withLock {
        $0.pasteLastTranscriptHotkey = HotKey(key: key, modifiers: modifiers.erasingSides())
      }
    }
  }

  private func handleCapture(_ keyEvent: KeyEvent, for target: HotKeyCaptureTarget, state: inout State) -> Effect<Action> {
    if keyEvent.key == .escape {
      endCapture(target, state: &state)
      return .none
    }

    let updatedModifiers = keyEvent.modifiers.union(captureModifiers(for: target, state: state))
    updateCaptureModifiers(updatedModifiers, for: target, state: &state)

    if target == .pasteLastTranscript, keyEvent.key != nil, updatedModifiers.isEmpty {
      return .none
    }

    if let key = keyEvent.key {
      applyCapturedHotKey(key: key, modifiers: updatedModifiers, for: target, state: &state)
      endCapture(target, state: &state)
      return .none
    }

    if target == .recording, keyEvent.modifiers.isEmpty {
      applyCapturedHotKey(key: nil, modifiers: updatedModifiers, for: target, state: &state)
      endCapture(target, state: &state)
    }

    return .none
  }

  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.modelDownload, action: \.modelDownload) {
      ModelDownloadFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        let didNormalizeDoubleTapOnly = !state.hexSettings.doubleTapLockEnabled && state.hexSettings.useDoubleTapOnly
        if didNormalizeDoubleTapOnly {
          state.$hexSettings.withLock {
            $0.useDoubleTapOnly = false
          }
        }

        return .none

      case .task:
        for role in RewriteEndpointRole.allCases {
          let account = state.hexSettings.endpoint(for: role).keychainAccount(role)
          state.rewriteAPIKeys[account] = keychain.read(account) ?? ""
        }
        state.localModelsDownloaded = Set(LocalLLMModel.allCases.filter(localLLM.isDownloaded))
        if let url = Bundle.main.url(forResource: "languages", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let languages = try? JSONDecoder().decode([Language].self, from: data)
        {
          state.languages = IdentifiedArray(uniqueElements: languages)
        } else {
          settingsLogger.error("Failed to load languages JSON from bundle")
        }

        // Listen for key events and load microphones (existing + new)
        return .run { send in
          func audioPropertyAddress(
            _ selector: AudioObjectPropertySelector,
            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
            element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
          ) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(
              mSelector: selector,
              mScope: scope,
              mElement: element
            )
          }

          await send(.modelDownload(.fetchModels))
          await send(.loadAvailableInputDevices)

          // Listen for device connection/disconnection notifications
          // Using a simpler debounced approach with a single task
          var deviceUpdateTask: Task<Void, Never>?
          var audioHardwareObservers: [(AudioObjectPropertySelector, SettingsAudioPropertyListenerBlock)] = []

          // Helper function to debounce device updates
          func debounceDeviceUpdate() {
            deviceUpdateTask?.cancel()
            deviceUpdateTask = Task {
              try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
              if !Task.isCancelled {
                await send(.loadAvailableInputDevices)
              }
            }
          }

          func installAudioHardwareObserver(_ selector: AudioObjectPropertySelector) {
            let listener: SettingsAudioPropertyListenerBlock = { _, _ in
              debounceDeviceUpdate()
            }
            var address = audioPropertyAddress(selector)
            let status = AudioObjectAddPropertyListenerBlock(
              AudioObjectID(kAudioObjectSystemObject),
              &address,
              DispatchQueue.main,
              listener
            )

            if status == noErr {
              audioHardwareObservers.append((selector, listener))
            } else {
              settingsLogger.error("Failed to observe audio hardware selector \(selector): \(status)")
            }
          }

          let deviceConnectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasConnected"),
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }
          
          let deviceDisconnectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasDisconnected"),
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }

          let appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }

          let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }

          installAudioHardwareObserver(kAudioHardwarePropertyDefaultInputDevice)
          installAudioHardwareObserver(kAudioHardwarePropertyDevices)

          // Be sure to clean up resources when the task is finished
          defer {
            deviceUpdateTask?.cancel()
            NotificationCenter.default.removeObserver(deviceConnectionObserver)
            NotificationCenter.default.removeObserver(deviceDisconnectionObserver)
            NotificationCenter.default.removeObserver(appDidBecomeActiveObserver)
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)

            for (selector, listener) in audioHardwareObservers {
              var address = audioPropertyAddress(selector)
              let status = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                listener
              )
              if status != noErr {
                settingsLogger.error("Failed to remove audio hardware observer for selector \(selector): \(status)")
              }
            }
          }

          for try await keyEvent in await keyEventMonitor.listenForKeyPress() {
            await send(.keyEvent(keyEvent))
          }
          
        }

      case .startSettingHotKey:
        beginCapture(.recording, state: &state)
        return .none

      case .addWordRemoval:
        state.$hexSettings.withLock {
          $0.wordRemovals.append(.init(pattern: ""))
        }
        return .none

      case let .updateWordRemoval(removal):
        state.$hexSettings.withLock {
          guard let index = $0.wordRemovals.firstIndex(where: { $0.id == removal.id }) else { return }
          $0.wordRemovals[index] = removal
        }
        return .none

      case let .removeWordRemoval(id):
        state.$hexSettings.withLock {
          $0.wordRemovals.removeAll { $0.id == id }
        }
        return .none

      case .addWordRemapping:
        state.$hexSettings.withLock {
          $0.wordRemappings.append(.init(match: "", replacement: ""))
        }
        return .none

      case let .updateWordRemapping(remapping):
        state.$hexSettings.withLock {
          guard let index = $0.wordRemappings.firstIndex(where: { $0.id == remapping.id }) else { return }
          $0.wordRemappings[index] = remapping
        }
        return .none

      case let .removeWordRemapping(id):
        state.$hexSettings.withLock {
          $0.wordRemappings.removeAll { $0.id == id }
        }
        return .none

      case let .setRemappingScratchpadFocused(isFocused):
        state.$isRemappingScratchpadFocused.withLock { $0 = isFocused }
        return .none

      case let .setLowercaseTranscripts(enabled):
        state.$hexSettings.withLock { $0.lowercaseTranscripts = enabled }
        return .none

      case let .setRemovePunctuation(enabled):
        state.$hexSettings.withLock { $0.removePunctuation = enabled }
        return .none

      case .startSettingPasteLastTranscriptHotkey:
        beginCapture(.pasteLastTranscript, state: &state)
        return .none
        
      case .clearPasteLastTranscriptHotkey:
        state.$hexSettings.withLock { $0.pasteLastTranscriptHotkey = nil }
        return .none

      case let .keyEvent(keyEvent):
        if state.isSettingPasteLastTranscriptHotkey {
          return handleCapture(keyEvent, for: .pasteLastTranscript, state: &state)
        }

        guard state.isSettingHotKey else { return .none }
        return handleCapture(keyEvent, for: .recording, state: &state)

      case let .toggleOpenOnLogin(enabled):
        state.$hexSettings.withLock { $0.openOnLogin = enabled }
        return .run { _ in
          if enabled {
            try? SMAppService.mainApp.register()
          } else {
            try? SMAppService.mainApp.unregister()
          }
        }

      case let .toggleShowDockIcon(enabled):
        state.$hexSettings.withLock { $0.showDockIcon = enabled }
        return .run { _ in
          await MainActor.run {
            NotificationCenter.default.post(name: .updateAppMode, object: nil)
          }
        }

      case let .togglePreventSystemSleep(enabled):
        state.$hexSettings.withLock { $0.preventSystemSleep = enabled }
        return .none

      case let .setUseClipboardPaste(enabled):
        state.$hexSettings.withLock { $0.useClipboardPaste = enabled }
        return .none

      case let .setCopyToClipboard(enabled):
        state.$hexSettings.withLock { $0.copyToClipboard = enabled }
        return .none

      case let .setRecordingAudioBehavior(behavior):
        state.$hexSettings.withLock { $0.recordingAudioBehavior = behavior }
        return .none

      case let .toggleSuperFastMode(enabled):
        state.$hexSettings.withLock { $0.superFastModeEnabled = enabled }
        return .run { _ in
          await recording.warmUpRecorder()
        }

      case let .setDoubleTapLockEnabled(enabled):
        state.$hexSettings.withLock {
          $0.doubleTapLockEnabled = enabled
          if !enabled {
            $0.useDoubleTapOnly = false
          }
        }
        return .none

      case let .setUseDoubleTapOnly(enabled):
        state.$hexSettings.withLock {
          $0.useDoubleTapOnly = enabled && $0.doubleTapLockEnabled
        }
        return .none

      case let .setMinimumKeyTime(value):
        state.$hexSettings.withLock { $0.minimumKeyTime = value }
        return .none

      case let .setOutputLanguage(language):
        state.$hexSettings.withLock { $0.outputLanguage = language }
        return .none

      case let .setSelectedMicrophoneID(deviceID):
        state.$hexSettings.withLock { $0.selectedMicrophoneID = deviceID }
        return .run { _ in
          await recording.warmUpRecorder()
        }

      case let .setRewriteMode(mode):
        state.$hexSettings.withLock { $0.rewriteMode = mode }
        return .none

      case let .setRewriteEndpoint(role, endpoint):
        state.$hexSettings.withLock {
          switch role {
          case .primary: $0.rewritePrimary = endpoint
          case .fallback: $0.rewriteFallback = endpoint
          }
        }
        return .none

      case let .setRewriteFallbackEnabled(enabled):
        state.$hexSettings.withLock { $0.rewriteFallbackEnabled = enabled }
        return .none

      case let .setRewriteModeShortcutsEnabled(enabled):
        state.$hexSettings.withLock { $0.rewriteModeShortcutsEnabled = enabled }
        return .none

      case let .setMergeIntoFieldEnabled(enabled):
        state.$hexSettings.withLock { $0.mergeIntoFieldEnabled = enabled }
        return .none

      case let .setContextTermsEnabled(enabled):
        state.$hexSettings.withLock { $0.contextTermsEnabled = enabled }
        return .none

      case let .setCaptureSentEdits(enabled):
        state.$hexSettings.withLock { $0.captureSentEdits = enabled }
        return .none

      case let .setMatchSurroundingText(enabled):
        state.$hexSettings.withLock { $0.matchSurroundingText = enabled }
        return .none

      case let .setSuperEnabled(enabled):
        state.$hexSettings.withLock { $0.superEnabled = enabled }
        return .none

      case let .setSuperEarlyDetection(enabled):
        state.$hexSettings.withLock { $0.superEarlyDetection = enabled }
        return .none

      case let .setURLActionsEnabled(enabled):
        state.$hexSettings.withLock { $0.urlActionsEnabled = enabled }
        return .none

      case let .setModeCyclerEnabled(enabled):
        state.$hexSettings.withLock { $0.modeCyclerEnabled = enabled }
        return .none

      case let .setCodeTalkEnabled(enabled):
        state.$hexSettings.withLock { $0.codeTalkEnabled = enabled }
        return .none

      case let .setVocabulary(terms):
        state.$hexSettings.withLock { $0.vocabulary = terms }
        return .none

      case let .setRewriteInstructions(mode, text):
        state.$hexSettings.withLock { $0.setCustomInstructions(text, for: mode) }
        return .none

      case let .setRewriteAPIKey(role, key):
        let account = state.hexSettings.endpoint(for: role).keychainAccount(role)
        state.rewriteAPIKeys[account] = key
        state.rewriteStatus[role] = nil
        return .run { [keychain] _ in
          do {
            try keychain.write(account, key.trimmingCharacters(in: .whitespacesAndNewlines))
          } catch {
            HexLog.rewrite.error("Saving the \(account, privacy: .public) API key failed: \(error.localizedDescription, privacy: .public)")
          }
        }

      case let .setRewriteProvider(role, provider):
        let current = state.hexSettings.endpoint(for: role)
        guard current.provider != provider else { return .none }
        var endpoint = RewriteEndpoint.preset(provider)
        // Prefer a model that's already on disk over the recommended one.
        if provider == .onDevice, !state.localModelsDownloaded.contains(.recommended),
           let downloaded = LocalLLMModel.allCases.first(where: state.localModelsDownloaded.contains) {
          endpoint.model = downloaded.repository
        }
        state.$hexSettings.withLock {
          switch role {
          case .primary: $0.rewritePrimary = endpoint
          case .fallback: $0.rewriteFallback = endpoint
          }
        }
        state.rewriteModelOptions[role] = nil
        state.rewriteStatus[role] = nil
        let account = endpoint.keychainAccount(role)
        if state.rewriteAPIKeys[account] == nil {
          state.rewriteAPIKeys[account] = keychain.read(account) ?? ""
        }
        return .none

      case let .loadRewriteModels(role):
        let endpoint = state.hexSettings.endpoint(for: role)
        let apiKey = state.apiKey(for: role)
        state.rewriteStatus[role] = .working("Loading models…")
        return .run { [rewrite] send in
          do {
            let models = try await rewrite.listModels(endpoint, apiKey)
            await send(.rewriteModelsLoaded(role, models))
            await send(.rewriteStatusChanged(role, .ok("\(models.count) models")))
          } catch {
            await send(.rewriteStatusChanged(role, .failed(Self.describeRewriteError(error, listingModels: true))))
          }
        }

      case let .rewriteModelsLoaded(role, models):
        state.rewriteModelOptions[role] = models
        return .none

      case let .connectRewriteEndpoint(role):
        let endpoint = state.hexSettings.endpoint(for: role)
        let apiKey = state.apiKey(for: role)
        if endpoint.provider.needsAPIKey, apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
          state.rewriteStatus[role] = .failed("Paste your API key first.")
          return .none
        }
        state.rewriteStatus[role] = .working("Connecting…")
        return .run { [rewrite] send in
          // The listing is best effort: some servers don't offer it, and the test below is what counts.
          if let models = try? await rewrite.listModels(endpoint, apiKey), !models.isEmpty {
            await send(.rewriteModelsLoaded(role, models))
            if !models.contains(endpoint.model), let better = endpoint.provider.preferredModel(from: models) {
              var updated = endpoint
              updated.model = better
              await send(.setRewriteEndpoint(role, updated))
            }
          }
          await send(.testRewriteEndpoint(role))
        }

      case let .testRewriteEndpoint(role):
        let endpoint = state.hexSettings.endpoint(for: role)
        let apiKey = state.apiKey(for: role)
        let mode = state.hexSettings.rewriteMode.rewrites ? state.hexSettings.rewriteMode : RewriteMode.clean
        let vocabulary = state.hexSettings.vocabulary
        state.rewriteStatus[role] = .working("Testing \(endpoint.model)…")
        return .run { [rewrite] send in
          let sample = "um so so I wanted to uh move the weekly sink to thursday and like tell the team"
          guard let messages = RewritePromptBuilder.messages(mode: mode, transcript: sample, vocabulary: vocabulary) else { return }
          let start = ContinuousClock.now
          do {
            let output = RewriteOutputSanitizer.sanitize(try await rewrite.complete(endpoint, apiKey, messages))
            let ms = Int((ContinuousClock.now - start) / .milliseconds(1))
            await send(.rewriteStatusChanged(role, .ok("\(ms) ms: \(output)")))
          } catch {
            await send(.rewriteStatusChanged(role, .failed(Self.describeRewriteError(error, listingModels: false))))
          }
        }

      case let .rewriteStatusChanged(role, status):
        state.rewriteStatus[role] = status
        return .none

      case .refreshLocalModels:
        state.localModelsDownloaded = Set(LocalLLMModel.allCases.filter(localLLM.isDownloaded))
        return .none

      case let .downloadLocalModel(model):
        guard state.localModelProgress[model] == nil else { return .none }
        state.localModelProgress[model] = 0
        state.localModelError = nil
        return .run { [localLLM] send in
          do {
            try await localLLM.download(model) { fraction in
              Task { await send(.localModelProgress(model, fraction)) }
            }
            await send(.localModelDownloadFinished(model, error: nil))
          } catch is CancellationError {
            await send(.localModelDownloadFinished(model, error: nil))
          } catch {
            await send(.localModelDownloadFinished(model, error: error.localizedDescription))
          }
        }
        .cancellable(id: LocalModelDownloadID(model: model), cancelInFlight: true)

      case let .localModelProgress(model, fraction):
        // A late progress update must not bring back a finished download's bar.
        if state.localModelProgress[model] != nil {
          state.localModelProgress[model] = fraction
        }
        return .none

      case let .localModelDownloadFinished(model, error):
        state.localModelProgress[model] = nil
        state.localModelError = error.map { "Downloading \(model.displayName) failed: \($0)" }
        state.localModelsDownloaded = Set(LocalLLMModel.allCases.filter(localLLM.isDownloaded))
        // The first download becomes the model in use, so setup is one click.
        if state.localModelsDownloaded.contains(model) {
          for role in RewriteEndpointRole.allCases {
            let endpoint = state.hexSettings.endpoint(for: role)
            let hasUsableModel = state.localModelsDownloaded.contains { $0.repository == endpoint.model }
            if endpoint.provider == .onDevice, !hasUsableModel {
              var updated = endpoint
              updated.model = model.repository
              state.$hexSettings.withLock {
                switch role {
                case .primary: $0.rewritePrimary = updated
                case .fallback: $0.rewriteFallback = updated
                }
              }
            }
          }
        }
        return .none

      case let .cancelLocalModelDownload(model):
        state.localModelProgress[model] = nil
        return .cancel(id: LocalModelDownloadID(model: model))

      case let .deleteLocalModel(model):
        state.localModelsDownloaded.remove(model)
        return .run { [localLLM] send in
          do {
            try await localLLM.delete(model)
          } catch {
            HexLog.rewrite.error("Deleting \(model.repository, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
          }
          await send(.refreshLocalModels)
        }

      case let .setVoiceIsolationEnabled(enabled):
        state.$hexSettings.withLock { $0.voiceIsolationEnabled = enabled }
        return .run { _ in await recording.warmUpRecorder() }

      case let .setVoiceIsolationInNotes(enabled):
        state.$hexSettings.withLock { $0.voiceIsolationInNotes = enabled }
        return .none

      case .showMicrophoneModes:
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
        return .none

      case let .setSoundEffectsEnabled(enabled):
        state.$hexSettings.withLock { $0.soundEffectsEnabled = enabled }
        return .run { _ in
          await soundEffects.setEnabled(enabled)
        }

      case let .setSoundEffectsVolume(volume):
        state.$hexSettings.withLock { $0.soundEffectsVolume = volume }
        return .none

      // Permission requests
      case .requestMicrophone:
        settingsLogger.info("User requested microphone permission from settings")
        return .none

      case .requestAccessibility:
        settingsLogger.info("User requested accessibility permission from settings")
        return .none

      case .requestInputMonitoring:
        settingsLogger.info("User requested input monitoring permission from settings")
        return .none

      // Model Management
      case .modelDownload:
        return .none
      
      // Microphone device selection
      case .loadAvailableInputDevices:
        return .run { send in
          let devices = await recording.getAvailableInputDevices()
          let defaultName = await recording.getDefaultInputDeviceName()
          await send(.availableInputDevicesLoaded(devices, defaultName))
        }
        
      case let .availableInputDevicesLoaded(devices, defaultName):
        if let selectedMicrophoneID = state.hexSettings.selectedMicrophoneID,
           let device = devices.first(where: { $0.legacyID == selectedMicrophoneID }) {
          state.availableInputDevices = devices
          state.defaultInputDeviceName = defaultName
          return .send(.setSelectedMicrophoneID(device.id))
        }
        state.availableInputDevices = devices
        state.defaultInputDeviceName = defaultName
        return .none
        
      case let .toggleSaveTranscriptionHistory(enabled):
        state.$hexSettings.withLock { $0.saveTranscriptionHistory = enabled }
        
        // If disabling history, delete all existing entries
        if !enabled {
          let transcripts = state.transcriptionHistory.history
          
          // Clear the history
          state.$transcriptionHistory.withLock { history in
            history.history.removeAll()
          }

          return deleteAudioEffect(for: transcripts)
        }
        
        return .none

      case let .setMaxHistoryEntries(maxHistoryEntries):
        state.$hexSettings.withLock { $0.maxHistoryEntries = maxHistoryEntries }
        return .none

      case let .setPrivateMode(isOn):
        state.$hexSettings.withLock { $0.privateMode = isOn }
        return .none

      case let .setCancelUndoSeconds(seconds):
        state.$hexSettings.withLock { $0.cancelUndoSeconds = seconds }
        return .none

      case let .setAudioRetentionDays(days):
        state.$hexSettings.withLock { $0.audioRetentionDays = days }
        return .run { _ in AudioRetentionSweep.run() }

      case let .setModifierSide(kind, side):
        guard state.hexSettings.hotkey.key == nil else { return .none }
        state.$hexSettings.withLock {
          $0.hotkey.modifiers = $0.hotkey.modifiers.setting(kind: kind, to: side)
        }
        return .none

      case let .setWordRemovalsEnabled(enabled):
        state.$hexSettings.withLock { $0.wordRemovalsEnabled = enabled }
        return .none

      }
    }
  }
}

// MARK: - LLM rewrite helpers

enum RewriteEndpointStatus: Equatable {
  case working(String)
  case ok(String)
  case failed(String)
}

private struct LocalModelDownloadID: Hashable {
  var model: LocalLLMModel
}

extension HexSettings {
  func endpoint(for role: RewriteEndpointRole) -> RewriteEndpoint {
    switch role {
    case .primary: rewritePrimary
    case .fallback: rewriteFallback
    }
  }
}

extension SettingsFeature {
  static func describeRewriteError(_ error: Error, listingModels: Bool) -> String {
    if case let ChatCompletionAPI.Failure.http(status, _) = error, status == 401 || status == 403 {
      return listingModels
        ? "HTTP \(status): listing models needs an API key here. You can still type a model ID."
        : "HTTP \(status): check the API key"
    }
    if case ChatCompletionAPI.Failure.http(404, _) = error {
      return "HTTP 404: unknown model or wrong base URL"
    }
    return error.localizedDescription
  }
}
