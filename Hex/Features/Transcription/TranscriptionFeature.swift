//
//  TranscriptionFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import CoreGraphics
import Foundation
import HexCore
import Inject
import os
import SwiftUI
import WhisperKit

private let transcriptionFeatureLogger = HexLog.transcription

@Reducer
struct TranscriptionFeature {
  @ObservableState
  struct State: Equatable {
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var isPrewarming: Bool = false
    /// The LLM rewrite of the last dictation is in flight (shown like transcribing).
    var isRewriting: Bool = false
    /// Counts dictations whose rewrite failed everywhere and were pasted as recognized; the indicator
    /// shows a notice each time it changes.
    var rewriteFallbackCount = 0
    /// The ⌃⌥ mode switcher's pick while Control is held; nil when it isn't in use.
    var modeCycler: ModeCyclerBar?
    var error: String?
    var recordingStartTime: Date?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    var sourceAppBundleID: String?
    var sourceAppName: String?
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
  }

  enum Action {
    case task
    case audioLevelUpdated(Meter)

    // Hotkey actions
    case hotKeyPressed
    case hotKeyReleased

    // Recording flow
    case startRecording
    case stopRecording

    // Cancel/discard flow
    case cancel   // Explicit cancellation with sound
    case discard  // Silent discard (too short/accidental)

    // Transcription result flow
    case transcriptionResult(String, URL, TimeInterval, DictationTimeline)
    case transcriptionError(Error, URL?)
    case rewriteStateChanged(Bool)
    case rewriteFellBack
    case modeCycler(ModeCycler.Output)
    case modeCyclerReveal

    // Model availability
    case modelMissing
  }

  enum CancelID {
    case metering
    case recordingStart
    case recordingCleanup
    case transcription
    case modeCyclerReveal
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.sleepManagement) var sleepManagement
  @Dependency(\.date.now) var now
  @Dependency(\.transcriptPersistence) var transcriptPersistence
  @Dependency(\.rewrite) var rewrite
  @Dependency(\.keychain) var keychain
  @Dependency(\.codeTalk) var codeTalk

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      // MARK: - Lifecycle / Setup

      case .task:
        // Starts two concurrent effects:
        // 1) Observing audio meter
        // 2) Monitoring hot key events
        // 3) Priming the recorder for instant startup
        return .merge(
          startMeteringEffect(),
          startHotKeyMonitoringEffect(),
          startModeCyclerEffect(),
          warmUpRecorderEffect()
        )

      // MARK: - Metering

      case let .audioLevelUpdated(meter):
        state.meter = meter
        return .none

      // MARK: - HotKey Flow

      case .hotKeyPressed:
        // If we're transcribing, send a cancel first. Otherwise start recording immediately.
        // We'll decide later (on release) whether to keep or discard the recording.
        return handleHotKeyPressed(isTranscribing: state.isTranscribing)

      case .hotKeyReleased:
        // If we're currently recording, then stop. Otherwise, just cancel
        // the delayed "startRecording" effect if we never actually started.
        return handleHotKeyReleased(isRecording: state.isRecording)

      // MARK: - Recording Flow

      case .startRecording:
        return handleStartRecording(&state)

      case .stopRecording:
        return handleStopRecording(&state)

      // MARK: - Transcription Results

      case let .transcriptionResult(result, audioURL, duration, timeline):
        return handleTranscriptionResult(&state, result: result, audioURL: audioURL, duration: duration, timeline: timeline)

      case let .rewriteStateChanged(isRewriting):
        state.isRewriting = isRewriting
        return .none

      case .rewriteFellBack:
        state.rewriteFallbackCount += 1
        return .none

      case let .modeCycler(output):
        return handleModeCycler(&state, output: output)

      case .modeCyclerReveal:
        state.modeCycler?.isVisible = true
        return .none

      case let .transcriptionError(error, audioURL):
        return handleTranscriptionError(&state, error: error, audioURL: audioURL)

      case .modelMissing:
        return .none

      // MARK: - Cancel/Discard Flow

      case .cancel:
        // Only cancel if we're in the middle of recording, transcribing, or post-processing
        guard state.isRecording || state.isTranscribing else {
          return .none
        }
        return handleCancel(&state)

      case .discard:
        // Silent discard for quick/accidental recordings
        guard state.isRecording else {
          return .none
        }
        return handleDiscard(&state)
      }
    }
  }
}

// MARK: - Effects: Metering & HotKey

private extension TranscriptionFeature {
  /// Effect to begin observing the audio meter.
  func startMeteringEffect() -> Effect<Action> {
    .run { send in
      for await meter in await recording.observeAudioLevel() {
        await send(.audioLevelUpdated(meter))
      }
    }
    .cancellable(id: CancelID.metering, cancelInFlight: true)
  }

  /// Feeds key events to `ModeCycler` (hold ⌃, press ⌥ to cycle modes) and ticks its auto-advance while
  /// Option is held. Outputs go through one stream so a quick tap's began → released → committed stay in order.
  func startModeCyclerEffect() -> Effect<Action> {
    .run { send in
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings
      let cycler = OSAllocatedUnfairLock(initialState: ModeCycler())
      let autoAdvance = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
      let (outputs, continuation) = AsyncStream.makeStream(of: ModeCycler.Output.self)

      @Sendable func setAutoAdvance(running: Bool) {
        autoAdvance.withLock { task in
          task?.cancel()
          task = running ? Task {
            while !Task.isCancelled {
              try? await Task.sleep(for: ModeCycler.autoAdvanceInterval)
              guard !Task.isCancelled, let next = cycler.withLock({ $0.advance() }) else { return }
              continuation.yield(.advanced(highlight: next))
            }
          } : nil
        }
      }

      let token = keyEventMonitor.handleKeyEvent { keyEvent in
        guard hexSettings.modeCyclerEnabled, !isSettingHotKey else { return false }
        let currentMode = hexSettings.rewriteMode
        guard let output = cycler.withLock({ $0.handle(keyEvent, currentMode: currentMode) }) else { return false }
        switch output {
        case .began, .advanced: setAutoAdvance(running: true)
        case .optionReleased, .committed, .aborted, .stepped: setAutoAdvance(running: false)
        }
        continuation.yield(output)
        return false // Never swallow: ⌃⌥ chords still reach the focused app
      }

      await withTaskCancellationHandler {
        for await output in outputs {
          await send(.modeCycler(output))
        }
      } onCancel: {
        token.cancel()
        continuation.finish()
        setAutoAdvance(running: false)
      }
    }
  }

  func handleModeCycler(_ state: inout State, output: ModeCycler.Output) -> Effect<Action> {
    switch output {
    case let .began(highlight):
      state.modeCycler = ModeCyclerBar(highlight: highlight, isVisible: false)
      return .run { send in
        try await Task.sleep(for: ModeCycler.revealDelay)
        await send(.modeCyclerReveal)
      }
      .cancellable(id: CancelID.modeCyclerReveal, cancelInFlight: true)

    case let .advanced(highlight):
      state.modeCycler = ModeCyclerBar(highlight: highlight, isVisible: true)
      return .cancel(id: CancelID.modeCyclerReveal)

    case .optionReleased:
      // A quick ⌃⌥ tap shows the pick right away instead of waiting for the delay.
      state.modeCycler?.isVisible = true
      return .cancel(id: CancelID.modeCyclerReveal)

    case let .committed(mode):
      state.modeCycler = nil
      state.$hexSettings.withLock { $0.rewriteMode = mode }
      HexLog.rewrite.info("Rewrite mode switched to \(mode.rawValue, privacy: .public) by the ⌃⌥ switcher")
      return .cancel(id: CancelID.modeCyclerReveal)

    case .aborted:
      state.modeCycler = nil
      return .cancel(id: CancelID.modeCyclerReveal)

    case let .stepped(mode):
      // Left Option + Control is an ordinary chord when nobody is talking.
      guard state.isRecording else { return .none }
      state.$hexSettings.withLock { $0.rewriteMode = mode }
      HexLog.rewrite.info("Rewrite mode stepped to \(mode.rawValue, privacy: .public) while recording")
      return .none
    }
  }

  /// Effect to start monitoring hotkey events through the `keyEventMonitor`.
  func startHotKeyMonitoringEffect() -> Effect<Action> {
    .run { send in
      var hotKeyProcessor: HotKeyProcessor = .init(hotkey: HotKey(key: nil, modifiers: [.option]))
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      // Handle incoming input events (keyboard and mouse)
      let token = keyEventMonitor.handleInputEvent { inputEvent in
        // Skip if the user is currently setting a hotkey
        if isSettingHotKey {
          return false
        }

        // Always keep hotKeyProcessor in sync with current user hotkey preference
        hotKeyProcessor.hotkey = hexSettings.hotkey
        let useDoubleTapOnly = hexSettings.doubleTapLockEnabled && hexSettings.useDoubleTapOnly
        hotKeyProcessor.doubleTapLockEnabled = hexSettings.doubleTapLockEnabled
        hotKeyProcessor.useDoubleTapOnly = useDoubleTapOnly
        hotKeyProcessor.minimumKeyTime = hexSettings.minimumKeyTime

        switch inputEvent {
        case .keyboard(let keyEvent):
          // If Escape is pressed with no modifiers while idle, let's treat that as `cancel`.
          if keyEvent.key == .escape, keyEvent.modifiers.isEmpty,
             hotKeyProcessor.state == .idle
          {
            Task { await send(.cancel) }
            return false
          }

		  // Process the key event
		  switch hotKeyProcessor.process(keyEvent: keyEvent) {
		  case .startRecording:
			Task { await send(.hotKeyPressed) }
            // If the hotkey is purely modifiers, return false to keep it from interfering with normal usage
            // But if useDoubleTapOnly is true, always intercept the key
            return useDoubleTapOnly || keyEvent.key != nil

          case .stopRecording:
            Task { await send(.hotKeyReleased) }
            return false // or `true` if you want to intercept

          case .cancel:
            Task { await send(.cancel) }
            return true

          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept - let the key chord reach other apps

          case .none:
            // If we detect repeated same chord, maybe intercept.
            if let pressedKey = keyEvent.key,
               pressedKey == hotKeyProcessor.hotkey.key,
               keyEvent.modifiers == hotKeyProcessor.hotkey.modifiers
            {
              return true
            }
            return false
          }

        case .mouseClick:
          // Process mouse click - for modifier-only hotkeys, this may cancel/discard
          switch hotKeyProcessor.processMouseClick() {
          case .cancel:
            Task { await send(.cancel) }
            return false // Don't intercept the click itself
          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept the click itself
          case .startRecording, .stopRecording, .none:
            return false
          }
        }
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
        }
      } onCancel: {
        token.cancel()
      }
    }
  }

  func warmUpRecorderEffect() -> Effect<Action> {
    .run { _ in
      await recording.warmUpRecorder()
    }
  }
}

// MARK: - HotKey Press/Release Handlers

private extension TranscriptionFeature {
  func handleHotKeyPressed(isTranscribing: Bool) -> Effect<Action> {
    // If already transcribing, cancel first. Otherwise start recording immediately.
    guard isTranscribing else { return .send(.startRecording) }
    return .concatenate(
      .send(.cancel),
      .send(.startRecording)
    )
  }

  func handleHotKeyReleased(isRecording: Bool) -> Effect<Action> {
    // Always stop recording when hotkey is released
    return isRecording ? .send(.stopRecording) : .none
  }
}

// MARK: - Recording Handlers

private extension TranscriptionFeature {
  func handleStartRecording(_ state: inout State) -> Effect<Action> {
    guard state.modelBootstrapState.isModelReady else {
      return .merge(
        .send(.modelMissing),
        .run { _ in soundEffect.play(.cancel) }
      )
    }
    state.isRecording = true
    let startTime = now
    state.recordingStartTime = startTime
    
    // Capture the active application
    if let activeApp = NSWorkspace.shared.frontmostApplication {
      state.sourceAppBundleID = activeApp.bundleIdentifier
      state.sourceAppName = activeApp.localizedName
    }
    transcriptionFeatureLogger.notice("Recording started at \(startTime.ISO8601Format())")

    // Prevent system sleep during recording
    return .merge(
      .cancel(id: CancelID.recordingCleanup),
      .run { [sleepManagement, preventSleep = state.hexSettings.preventSystemSleep] _ in
        // Play sound immediately for instant feedback
        soundEffect.play(.startRecording)

        if preventSleep {
          await sleepManagement.preventSleep(reason: "Hex Voice Recording")
        }
        guard !Task.isCancelled else {
          if preventSleep {
            await sleepManagement.allowSleep()
          }
          return
        }
        await recording.startRecording()
      }
      .cancellable(id: CancelID.recordingStart, cancelInFlight: true)
    )
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    let keyUp = stampLatency("keyUp")

    let stopTime = now
    let startTime = state.recordingStartTime
    let duration = startTime.map { stopTime.timeIntervalSince($0) } ?? 0

    let decision = RecordingDecisionEngine.decide(
      .init(
        hotkey: state.hexSettings.hotkey,
        minimumKeyTime: state.hexSettings.minimumKeyTime,
        recordingStartTime: state.recordingStartTime,
        currentTime: stopTime
      )
    )

    let startStamp = startTime?.ISO8601Format() ?? "nil"
    let stopStamp = stopTime.ISO8601Format()
    let minimumKeyTime = state.hexSettings.minimumKeyTime
    let hotkeyHasKey = state.hexSettings.hotkey.key != nil
    transcriptionFeatureLogger.notice(
      "Recording stopped duration=\(String(format: "%.3f", duration))s start=\(startStamp) stop=\(stopStamp) decision=\(String(describing: decision)) minimumKeyTime=\(String(format: "%.2f", minimumKeyTime)) hotkeyHasKey=\(hotkeyHasKey)"
    )

    guard decision == .proceedToTranscription else {
      // If the user recorded for less than minimumKeyTime and the hotkey is modifier-only,
      // discard the audio to avoid accidental triggers.
      transcriptionFeatureLogger.notice("Discarding short recording per decision \(String(describing: decision))")
      return handleDiscard(&state)
    }

    let model = state.hexSettings.selectedModel
    guard !model.isEmpty else {
      // Defense-in-depth: handleStartRecording already blocks recording when the
      // bootstrap state says no model is ready, but settings can change while a
      // recording is in flight (or the in-memory bootstrap default can race a
      // cold launch). Never hand an empty model name to the transcriber: it
      // silently produces nothing (or junk like "[BLANK_AUDIO]").
      transcriptionFeatureLogger.error("Recording stopped with no transcription model selected; discarding audio")
      return .merge(
        handleDiscard(&state),
        .send(.modelMissing)
      )
    }

    // Otherwise, proceed to transcription
    state.isTranscribing = true
    state.error = nil
    let language = state.hexSettings.outputLanguage

    state.isPrewarming = true

    return .merge(
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement] send in
        // Allow system to sleep again
        await sleepManagement.allowSleep()

        var timeline = DictationTimeline(keyUp: keyUp)
        var audioURL: URL?
        defer {
          if let audioURL {
            FileManager.default.removeItemIfExists(at: audioURL)
          }
        }
        do {
          let stopResult = await recording.stopRecording()
          let capturedURL: URL
          switch stopResult {
          case let .captured(url):
            capturedURL = url
          case .ignored(.staleSession):
            transcriptionFeatureLogger.notice("Ignoring transcription stop superseded by a newer recording session")
            return
          case .ignored(.noActiveRecording):
            transcriptionFeatureLogger.error("Recording stopped without captured audio")
            await send(.transcriptionError(RecordingFailure.noCapturedAudio, nil))
            return
          case let .failed(error):
            transcriptionFeatureLogger.error("Recording stop failed: \(error.localizedDescription)")
            await send(.transcriptionError(error, nil))
            return
          }
          audioURL = capturedURL
          timeline.captureStopped = stampLatency("captureStopped")
          guard !Task.isCancelled else { return }
          soundEffect.play(.stopRecording)

          // Create transcription options with the selected language
          // Note: cap concurrency to avoid audio I/O overloads on some Macs
          let decodeOptions = DecodingOptions(
            language: language,
            detectLanguage: language == nil, // Only auto-detect if no language specified
            chunkingStrategy: .vad,
          )

          let result = try await transcription.transcribe(capturedURL, model, decodeOptions) { _ in }
          timeline.transcribed = stampLatency("transcribed")

          transcriptionFeatureLogger.notice("Transcribed audio from \(capturedURL.lastPathComponent) to text length \(result.count)")
          audioURL = nil
          await send(.transcriptionResult(result, capturedURL, duration, timeline))
        } catch {
          transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription)")
          await send(.transcriptionError(error, nil))
        }
      }
      .cancellable(id: CancelID.transcription)
    )
  }
}

// MARK: - Transcription Handlers

private extension TranscriptionFeature {
  func handleTranscriptionResult(
    _ state: inout State,
    result: String,
    audioURL: URL,
    duration: TimeInterval,
    timeline: DictationTimeline
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false

    // Check for force quit command (emergency escape hatch)
    if ForceQuitCommandDetector.matches(result) {
      transcriptionFeatureLogger.fault("Force quit voice command recognized; terminating Hex.")
      return .run { _ in
        FileManager.default.removeItemIfExists(at: audioURL)
        await MainActor.run {
          NSApp.terminate(nil)
        }
      }
    }

    // If empty text, nothing else to do
    guard !result.isEmpty else {
      return .run { _ in
        FileManager.default.removeItemIfExists(at: audioURL)
      }
    }

    transcriptionFeatureLogger.info("Raw transcription: '\(result, privacy: .private)'")
    let settings = state.hexSettings
    let skipModifications = state.isRemappingScratchpadFocused
    if skipModifications {
      transcriptionFeatureLogger.info("Scratchpad focused; skipping word modifications and rewrite")
    }

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory
    let engine = settings.selectedModel
    let rewriteMode = skipModifications ? RewriteMode.raw : settings.rewriteMode

    return .run { send in
      var timeline = timeline
      var output = skipModifications ? result : applyWordModifications(result, settings: settings)
      var appliedRewrite: RewriteMode?
      var rewriteOutcome: RewriteOutcome?

      // Code talk: a leading "slash <command>" is resolved here so it survives a failed rewrite,
      // and only the rest of the dictation goes to the LLM.
      var codeTalkCommands: [String]?
      var leadingCommand: CodeTalk.LeadingCommand?
      if rewriteMode == .prompt, settings.codeTalkEnabled {
        let commands = codeTalk.slashCommands()
        codeTalkCommands = commands
        leadingCommand = CodeTalk.leadingCommand(in: output, commands: commands)
        if let leadingCommand {
          HexLog.rewrite.info("Code talk resolved \(leadingCommand.command, privacy: .public)")
          output = leadingCommand.remainder
        }
      }

      if rewriteMode != .raw, !output.isEmpty {
        await send(.rewriteStateChanged(true))
        let outcome = await rewriteTranscript(
          output,
          mode: rewriteMode,
          settings: settings,
          targetAppName: sourceAppName,
          codeTalkCommands: codeTalkCommands
        )
        await send(.rewriteStateChanged(false))
        timeline.rewritten = stampLatency("rewritten")
        guard !Task.isCancelled else {
          FileManager.default.removeItemIfExists(at: audioURL)
          return
        }
        rewriteOutcome = outcome
        if outcome.rewrittenBy != nil {
          output = outcome.text
          appliedRewrite = rewriteMode
        } else if !outcome.failures.isEmpty {
          await send(.rewriteFellBack)
        }
      }
      if let leadingCommand {
        output = CodeTalk.join(leadingCommand, rewrittenRemainder: output)
      }

      if !skipModifications {
        let formatted = TranscriptFormattingApplier.apply(
          output,
          lowercase: settings.lowercaseTranscripts,
          removePunctuation: settings.removePunctuation
        )
        if formatted != output {
          transcriptionFeatureLogger.info("Applied paste formatting")
        }
        output = formatted
      }

      guard !output.isEmpty else {
        FileManager.default.removeItemIfExists(at: audioURL)
        return
      }

      do {
        try await finalizeRecordingAndStoreTranscript(
          result: output,
          rawText: appliedRewrite == nil && leadingCommand == nil ? nil : result,
          rewriteMode: appliedRewrite,
          rewriteOutcome: rewriteOutcome,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          transcriptionHistory: transcriptionHistory,
          timeline: timeline,
          engine: engine
        )
      } catch {
        await send(.transcriptionError(error, audioURL))
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  /// Word removals then remappings, as configured in Settings.
  func applyWordModifications(_ text: String, settings: HexSettings) -> String {
    var output = text
    if settings.wordRemovalsEnabled {
      let removedResult = WordRemovalApplier.apply(output, removals: settings.wordRemovals)
      if removedResult != output {
        let enabledRemovalCount = settings.wordRemovals.filter(\.isEnabled).count
        transcriptionFeatureLogger.info("Applied \(enabledRemovalCount) word removal(s)")
      }
      output = removedResult
    }
    let remappedResult = WordRemappingApplier.apply(output, remappings: settings.wordRemappings)
    if remappedResult != output {
      transcriptionFeatureLogger.info("Applied \(settings.wordRemappings.count) word remapping(s)")
    }
    return remappedResult
  }

  /// Primary endpoint, then the fallback; returns the transcript unchanged if both fail,
  /// so a network problem never costs the dictation.
  func rewriteTranscript(
    _ transcript: String,
    mode: RewriteMode,
    settings: HexSettings,
    targetAppName: String?,
    codeTalkCommands: [String]? = nil
  ) async -> RewriteOutcome {
    var endpoints: [(RewriteEndpointRole, RewriteEndpoint)] = [(.primary, settings.rewritePrimary)]
    if settings.rewriteFallbackEnabled {
      endpoints.append((.fallback, settings.rewriteFallback))
    }
    let outcome = await RewriteChain.run(
      transcript: transcript,
      mode: mode,
      vocabulary: settings.vocabulary,
      targetAppName: targetAppName,
      instructions: settings.customInstructions(for: mode),
      codeTalkCommands: codeTalkCommands,
      endpoints: endpoints
    ) { [rewrite, keychain] role, endpoint, messages in
      try await rewrite.complete(endpoint, keychain.read(role.keychainAccount), messages)
    }
    for failure in outcome.failures {
      HexLog.rewrite.error("Rewrite failed: \(failure, privacy: .public)")
    }
    if let model = outcome.rewrittenBy {
      HexLog.rewrite.info("Rewrote with \(model, privacy: .public) (\(mode.rawValue, privacy: .public))")
    } else {
      HexLog.rewrite.notice("Every rewrite endpoint failed; pasting the transcript as recognized")
    }
    return outcome
  }

  func handleTranscriptionError(
    _ state: inout State,
    error: Error,
    audioURL: URL?
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.error = error.localizedDescription
    
    if let audioURL {
      FileManager.default.removeItemIfExists(at: audioURL)
    }

    return .none
  }

  /// Move file to permanent location, create a transcript record, paste text, and play sound.
  func finalizeRecordingAndStoreTranscript(
    result: String,
    rawText: String?,
    rewriteMode: RewriteMode?,
    rewriteOutcome: RewriteOutcome?,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
    audioURL: URL,
    transcriptionHistory: Shared<TranscriptionHistory>,
    timeline: DictationTimeline,
    engine: String
  ) async throws {
    var timeline = timeline
    var savedTranscriptID: UUID?
    @Shared(.hexSettings) var hexSettings: HexSettings

    if hexSettings.saveTranscriptionHistory {
      var transcript = try await transcriptPersistence.save(
        result,
        audioURL,
        duration,
        sourceAppBundleID,
        sourceAppName
      )
      transcript.rawText = rawText
      transcript.rewriteMode = rewriteMode
      transcript.rewrittenBy = rewriteOutcome?.rewrittenBy
      transcript.rewriteFailures = rewriteOutcome.flatMap { $0.failures.isEmpty ? nil : $0.failures }
      savedTranscriptID = transcript.id

      transcriptionHistory.withLock { history in
        history.history.insert(transcript, at: 0)

        if let maxEntries = hexSettings.maxHistoryEntries, maxEntries > 0 {
          while history.history.count > maxEntries {
            if let removedTranscript = history.history.popLast() {
              Task {
                 try? await transcriptPersistence.deleteAudio(removedTranscript)
              }
            }
          }
        }
      }
    } else {
      FileManager.default.removeItemIfExists(at: audioURL)
    }

    timeline.postProcessed = stampLatency("postProcessed")

    await pasteboard.paste(result)
    timeline.pasted = stampLatency("pasted")
    soundEffect.play(.pasteTranscript)

    if let latency = timeline.latency(audioSeconds: duration, engine: engine) {
      HexLog.latency.notice("Dictation latency \(latency.summary, privacy: .public) engine=\(engine, privacy: .public)")
      @Shared(.lastDictationLatency) var lastDictationLatency: DictationLatency?
      $lastDictationLatency.withLock { $0 = latency }
      if let savedTranscriptID {
        transcriptionHistory.withLock { history in
          guard let index = history.history.firstIndex(where: { $0.id == savedTranscriptID }) else { return }
          history.history[index].latency = latency
        }
      }
    }
  }

  /// Marks a pipeline stage in Instruments' os_signpost track and returns the stage time.
  func stampLatency(_ stage: StaticString) -> ContinuousClock.Instant {
    HexLog.latencySignposter.emitEvent(stage)
    return .now
  }
}

// MARK: - Cancel/Discard Handlers

private extension TranscriptionFeature {
  func handleCancel(_ state: inout State) -> Effect<Action> {
    let wasRecording = state.isRecording
    state.isTranscribing = false
    state.isRecording = false
    state.isPrewarming = false
    state.isRewriting = false

    return .merge(
      .cancel(id: CancelID.transcription),
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        guard wasRecording else {
          soundEffect.play(.cancel)
          return
        }
        // Stop the recording to release microphone access
		let result = await recording.stopRecording()
		if case let .captured(url) = result {
		  FileManager.default.removeItemIfExists(at: url)
		}
		guard !Task.isCancelled else { return }
		soundEffect.play(.cancel)
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }

  func handleDiscard(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.isPrewarming = false

    // Silently discard - no sound effect
    return .merge(
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
		let result = await recording.stopRecording()
		if case let .captured(url) = result {
		  FileManager.default.removeItemIfExists(at: url)
		}
		guard !Task.isCancelled else { return }
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }
}

// MARK: - View

struct TranscriptionView: View {
  @Bindable var store: StoreOf<TranscriptionFeature>
  @ObserveInjection var inject

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// A one-off notice (mode change, rewrite fallback) and the id of its hide timer.
  @State private var notice: DictationNotice?
  @State private var noticeID = 0

  var status: TranscriptionIndicatorView.Status {
    if store.isTranscribing {
      return .transcribing
    } else if store.isRewriting && !store.isRecording {
      return .rewriting
    } else if store.isRecording {
      return .recording
    } else if store.isPrewarming {
      return .prewarming
    } else {
      return .hidden
    }
  }

  private var cyclerHighlight: RewriteMode? {
    guard let bar = store.modeCycler, bar.isVisible else { return nil }
    return bar.highlight
  }

  /// A one-off notice wins; otherwise a non-Clean mode is tagged while recording.
  private var visibleNotice: DictationNotice? {
    if let notice { return notice }
    let mode = store.hexSettings.rewriteMode
    return store.isRecording && mode != .clean ? .recordingIn(mode) : nil
  }

  var body: some View {
    VStack(spacing: 8) {
      TranscriptionIndicatorView(
        status: status,
        meter: store.meter
      )
      ZStack {
        if let cyclerHighlight {
          ModeCyclerBarView(highlight: cyclerHighlight)
            .transition(DictationNoticeView.transition(reduceMotion: reduceMotion))
        } else if let visibleNotice {
          DictationNoticeView(notice: visibleNotice)
            .transition(DictationNoticeView.transition(reduceMotion: reduceMotion))
        }
      }
      .animation(DictationNoticeView.entrance, value: cyclerHighlight == nil)
      // Only appearing and disappearing animate; a notice replacing another swaps in place.
      .animation(
        visibleNotice == nil ? DictationNoticeView.exit : DictationNoticeView.entrance,
        value: visibleNotice == nil
      )
    }
    .onChange(of: store.hexSettings.rewriteMode) { _, mode in
      show(.modeChanged(mode))
    }
    .onChange(of: store.rewriteFallbackCount) { _, _ in
      show(.rewriteFellBack)
    }
    .task(id: noticeID) {
      guard let hold = notice?.holdDuration else { return }
      try? await Task.sleep(for: hold)
      guard !Task.isCancelled else { return }
      notice = nil
    }
    .task {
      await store.send(.task).finish()
    }
    .enableInjection()
  }

  /// Shows `next`, restarting the hide timer. Replacing a visible notice swaps the text in place.
  private func show(_ next: DictationNotice) {
    notice = next
    noticeID += 1
  }
}

// MARK: - Force Quit Command

private enum ForceQuitCommandDetector {
  static func matches(_ text: String) -> Bool {
    let normalized = normalize(text)
    return normalized == "force quit hex now" || normalized == "force quit hex"
  }

  private static func normalize(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
