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
    /// What the live caption shows while recording (Apple's streaming recognizer on the dictation's own audio);
    /// nil outside a dictation. Never pasted or stored.
    var caption: CaptionText?
    var isTranscribing: Bool = false
    var isPrewarming: Bool = false
    /// The last dictation hasn't been pasted yet; the talk key is ignored until it is.
    var isProcessing: Bool { isTranscribing || isRewriting }
    /// The LLM rewrite of the last dictation is in flight (shown like transcribing).
    var isRewriting: Bool = false
    /// Counts dictations whose rewrite failed everywhere and were pasted as recognized; the indicator
    /// shows a notice each time it changes.
    var rewriteFallbackCount = 0
    /// The ⌃⌥ mode switcher's pick while Control is held; nil when it isn't in use.
    var modeCycler: ModeCyclerBar?
    /// The notes session being recorded (Notes mode: tap the talk key to start, tap again to stop).
    var notesRecording: NotesRecording?
    /// The latest notice for the pill (notes, a kept failed dictation); a new `serial` shows it again.
    var notice: NoticeRequest?
    var error: String?
    var recordingStartTime: Date?
    /// A dictation pressed in Notes mode that outlasted the tap window (`NotesTapDetector.tapWindow`): it is
    /// dictated in `HexSettings.dictationMode`, and the pill says so.
    var notesHold = false
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    var sourceAppBundleID: String?
    var sourceAppName: String?
    /// The focused field when the talk key went down: its names become spelling hints (`ContextTerms`), and
    /// a Legacy dictation edits its selection or writes into it.
    var fieldContext: FocusedText?
    /// `fieldContext` kept past key-up for a Legacy dictation.
    var superField: FocusedText?
    /// This dictation is a Legacy instruction; the pill says so until the answer is pasted or fails.
    var superActive = false
    /// Spelling hints for this dictation, built at key-up.
    var biasing: BiasingContext = .empty
    /// A cancelled dictation kept for Undo (`HexSettings.cancelUndoSeconds`); its recording goes when this expires.
    var cancelled: CancelledDictation?
    /// The cancelled dictation Undo is transcribing again: it's pasted only into the app it was meant for.
    var undone: CancelledDictation?
    /// Shared with the effects: the recording being transcribed, and whether a dictation is still processing.
    var inFlight = DictationInFlight()
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.isNotesRecording) var isNotesRecording: Bool = false
    /// Settings has the sample caption up for the user to drag; a talk-key press ends it.
    @Shared(.isPlacingCaption) var isPlacingCaption: Bool = false
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
    /// The capture engine is running; the speech and rewrite models start loading only now.
    case microphoneReady
    case stopRecording
    case captionUpdated(CaptionText)

    // Cancel/discard flow
    case cancel   // Explicit cancellation with sound
    case discard  // Silent discard (too short/accidental)
    /// A cancel kept the recording; the Undo pill shows until `cancelUndoSeconds` pass.
    case cancelKept(CancelledDictation)
    /// The Undo button: the cancelled dictation is transcribed and rewritten as if it hadn't been cancelled.
    case undoCancel
    case cancelUndoExpired(UUID)
    /// Undo finished in another app than the dictation's, so nothing was pasted.
    case undoNotPasted(DictationNotice)

    // Transcription result flow
    case transcriptionResult(String, URL, TimeInterval, DictationTimeline)
    case transcriptionError(Error, URL?)
    /// Speech-to-text failed on a captured recording, which is kept in History for Retry.
    case transcriptionFailed(Error, URL, TimeInterval)
    case failedDictationKept
    case rewriteStateChanged(Bool)
    case fieldContextCaptured(FocusedText?)
    case rewriteFellBack
    /// Apple Speech's peek at the first seconds of the recording did (or didn't) hear "legacy".
    case superHeard(Bool)
    /// A Legacy dictation ended; the notice says why when nothing was pasted.
    case superFinished(DictationNotice?)
    case modeCycler(ModeCycler.Output)
    case modeCyclerReveal

    // Model availability
    case modelMissing

    // Notes sessions
    case notesTapped
    /// A press in Notes mode held past the tap window: it's a dictation, not a session.
    case notesHoldConfirmed
    /// A finished session in which nothing was heard was deleted.
    case notesDiscardedSilent
    case notesStarted(String)
    case notesStartFailed(String)
    case notesStop
    case notesWarn
    case notesCaptureFailed(String)
    case notesSilent

    /// A `legacyscribe://` URL (`HexAppDelegate.application(_:open:)`).
    case urlAction(URLAction)
  }

  enum CancelID {
    case metering
    case recordingStart
    case recordingCleanup
    case transcription
    case modeCyclerReveal
    case notesMetering
    case notesTimer
    case superPeek
    case cancelUndo
    case notesHold
    case liveCaption
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.sleepManagement) var sleepManagement
  @Dependency(\.date.now) var now
  @Dependency(\.continuousClock) var clock
  @Dependency(\.transcriptPersistence) var transcriptPersistence
  @Dependency(\.localLLM) var localLLM
  /// Word fixes and the rewrite chain, shared with History's Retry.
  let rewriter = TranscriptRewriter()
  @Dependency(\.codeTalk) var codeTalk
  @Dependency(\.focusedText) var focusedText
  @Dependency(\.speechPeek) var speechPeek
  @Dependency(\.liveCaption) var liveCaption
  @Dependency(\.notes) var notes

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
          startHotKeyMonitoringEffect(inFlight: state.inFlight),
          startModeCyclerEffect(),
          startSentEditCaptureEffect(),
          startNotesEventsEffect(),
          warmUpRecorderEffect()
        )

      // MARK: - Metering

      case let .audioLevelUpdated(meter):
        state.meter = meter
        return .none

      // MARK: - HotKey Flow

      case .hotKeyPressed:
        // The last dictation finishes first: a stray press right after letting go used to cancel it. Esc
        // still cancels, with Undo. On release we decide whether to keep or discard the recording.
        guard !state.isProcessing else {
          transcriptionFeatureLogger.notice("Talk key pressed while the last dictation is still processing; ignored")
          return .none
        }
        return .send(.startRecording)

      case .hotKeyReleased:
        // If we're currently recording, then stop. Otherwise, just cancel
        // the delayed "startRecording" effect if we never actually started.
        return handleHotKeyReleased(isRecording: state.isRecording)

      // MARK: - Recording Flow

      case .startRecording:
        return handleStartRecording(&state)

      case .microphoneReady:
        return handleMicrophoneReady(state)

      case .stopRecording:
        return handleStopRecording(&state)

      case let .captionUpdated(text):
        // A late update after key-up (the stream is cancelled, but one may be in flight) shows nothing.
        if state.isRecording { state.caption = text }
        return .none

      // MARK: - Transcription Results

      case let .transcriptionResult(result, audioURL, duration, timeline):
        return handleTranscriptionResult(&state, result: result, audioURL: audioURL, duration: duration, timeline: timeline)

      case let .rewriteStateChanged(isRewriting):
        state.isRewriting = isRewriting
        return .none

      case let .fieldContextCaptured(field):
        // Only for the dictation it was read for.
        guard state.isRecording else { return .none }
        state.fieldContext = field
        if let field, field.selectionLength > 0, state.hexSettings.superEnabled,
           state.hexSettings.superHintsShown < SuperTrigger.hintLimit {
          state.$hexSettings.withLock { $0.superHintsShown += 1 }
          state.showNotice(.superHint)
        }
        return .none

      case .rewriteFellBack:
        state.rewriteFallbackCount += 1
        return .none

      case let .superHeard(isSuper):
        // The final transcript decides; this only changes the look while recording.
        guard state.isRecording, state.superActive != isSuper else { return .none }
        state.superActive = isSuper
        transcriptionFeatureLogger.info("Legacy \(isSuper ? "heard" : "not heard", privacy: .public) early")
        let settings = state.hexSettings
        // Raw mode doesn't warm the on-device model at key-down; Legacy needs it.
        guard isSuper, !settings.dictationMode.rewrites, settings.rewritePrimary.provider == .onDevice else { return .none }
        return .run { [localLLM] _ in await localLLM.prewarm(settings.rewritePrimary.model) }

      case let .superFinished(notice):
        state.superActive = false
        if let notice { state.showNotice(notice) }
        return .none

      case let .modeCycler(output):
        return handleModeCycler(&state, output: output)

      case .modeCyclerReveal:
        state.modeCycler?.isVisible = true
        return .none

      case let .transcriptionFailed(error, audioURL, duration):
        return handleTranscriptionFailed(&state, error: error, audioURL: audioURL, duration: duration)

      case .failedDictationKept:
        state.showNotice(.dictationKept)
        return .none

      case let .transcriptionError(error, audioURL):
        return handleTranscriptionError(&state, error: error, audioURL: audioURL)

      case .modelMissing:
        return .none

      // MARK: - Notes Sessions

      case .notesTapped:
        if let session = state.notesRecording {
          // A habitual double-tap shouldn't end the session it just started.
          guard now.timeIntervalSince(session.startedAt) > 0.6 else { return .none }
          return handleNotesStop(&state)
        }
        // The tap's own press started a dictation (Notes mode holds dictate); the session replaces it.
        guard state.isRecording else { return handleNotesStart(&state) }
        let discard = handleDiscard(&state)
        return .merge(discard, handleNotesStart(&state))

      case .notesHoldConfirmed:
        guard state.isRecording else { return .none }
        state.notesHold = true
        return .run { _ in soundEffect.play(.startRecording) }

      case .notesDiscardedSilent:
        state.showNotice(.notesDiscarded(silent: true))
        return .none

      case let .notesStarted(id):
        state.notesRecording?.id = id
        return state.notesRecording?.stopRequested == true ? handleNotesStop(&state) : .none

      case let .notesStartFailed(message):
        state.notesRecording = nil
        state.$isNotesRecording.withLock { $0 = false }
        state.meter = .init(averagePower: 0, peakPower: 0)
        state.showNotice(.notesProblem(message))
        return .merge(
          .cancel(id: CancelID.notesMetering),
          .cancel(id: CancelID.notesTimer),
          .run { [sleepManagement] _ in
            soundEffect.play(.cancel)
            await sleepManagement.allowSleep()
          }
        )

      case .notesStop:
        return handleNotesStop(&state)

      case .notesWarn:
        guard state.notesRecording != nil else { return .none }
        state.showNotice(.notesEnding)
        return .none

      case let .notesCaptureFailed(message):
        guard state.notesRecording != nil else { return .none }
        state.showNotice(.notesProblem(message))
        return .none

      case .notesSilent:
        guard state.notesRecording != nil else { return .none }
        let stop = handleNotesStop(&state)
        state.showNotice(.notesStoppedSilent)
        return stop

      case let .urlAction(action):
        return handleURLAction(&state, action)

      // MARK: - Cancel/Discard Flow

      case .cancel:
        // Esc ends a notes session and keeps it, unless it's in its first seconds.
        if state.notesRecording != nil {
          return handleNotesStop(&state, discardingUnder: NotesSession.escapeDiscardSeconds)
        }
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

      case let .cancelKept(kept):
        // A newer cancel replaces the offer; the older recording goes.
        let replaced = state.cancelled
        state.cancelled = kept
        let seconds = state.hexSettings.cancelUndoSeconds
        transcriptionFeatureLogger.notice("Cancelled dictation kept for Undo for \(seconds, privacy: .public) s")
        return .merge(
          .run { _ in
            if let replaced { FileManager.default.removeItemIfExists(at: replaced.audioURL) }
          },
          .run { [clock] send in
            try await clock.sleep(for: .seconds(seconds))
            await send(.cancelUndoExpired(kept.id))
          }
          .cancellable(id: CancelID.cancelUndo, cancelInFlight: true)
        )

      case let .cancelUndoExpired(id):
        guard let kept = state.cancelled, kept.id == id else { return .none }
        state.cancelled = nil
        return .run { _ in FileManager.default.removeItemIfExists(at: kept.audioURL) }

      case .undoCancel:
        guard let kept = state.cancelled, !state.isRecording, !state.isProcessing, state.notesRecording == nil else {
          return .none
        }
        state.cancelled = nil
        return .merge(.cancel(id: CancelID.cancelUndo), handleUndo(&state, kept))

      case let .undoNotPasted(notice):
        state.showNotice(notice)
        return .none
      }
    }
    // The hotkey monitor reads this to keep presses away from the processor while a dictation processes.
    .onChange(of: \.isProcessing) { _, isProcessing in
      Reduce { state, _ in
        state.inFlight.isProcessing = isProcessing
        return .none
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

  /// On Enter (or ⌘Enter) in the field of the last paste, reads the field before the app handles the key
  /// and stores the pasted stretch as sent (`SentEdit`). Shift-Enter is a newline in chat apps, so it's ignored.
  func startSentEditCaptureEffect() -> Effect<Action> {
    .run { [focusedText] _ in
      @Shared(.pendingSentEdit) var pendingSentEdit: PendingSentEdit?
      @Shared(.sentEdits) var sentEdits: SentEditLog

      let token = keyEventMonitor.handleKeyEvent { keyEvent in
        guard keyEvent.key == .return || keyEvent.key == .keypadEnter,
              keyEvent.modifiers.isEmpty || keyEvent.modifiers.matchesExactly([.command]),
              let pending = pendingSentEdit
        else { return false }
        let date = Date()
        if pending.isExpired(at: date) {
          $pendingSentEdit.withLock { $0 = nil }
          return false
        }
        // Runs inside the event tap, before the app sees Enter, so the field still holds the message.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == pending.bundleID,
              let field = focusedText.read(), field.bundleID == pending.bundleID,
              let edit = pending.sentEdit(finalField: field.value, at: date)
        else { return false } // Another field or unreadable: keep waiting for the right Enter.
        $pendingSentEdit.withLock { $0 = nil }
        Task { @MainActor in
          $sentEdits.withLock { $0.edits.append(edit) }
        }
        HexLog.learning.info("Captured sent text (edited: \(edit.wasEdited, privacy: .public)) in \(pending.bundleID, privacy: .public)")
        return false
      }

      await withTaskCancellationHandler {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
        }
      } onCancel: {
        token.cancel()
      }
    }
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
  func startHotKeyMonitoringEffect(inFlight: DictationInFlight) -> Effect<Action> {
    .run { send in
      var hotKeyProcessor: HotKeyProcessor = .init(hotkey: HotKey(key: nil, modifiers: [.option]))
      var notesTaps = NotesTapDetector(hotkey: HotKey(key: nil, modifiers: [.option]))
      var notesPressBeganIdle = false
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings
      @Shared(.isNotesRecording) var isNotesRecording: Bool

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
        notesTaps.hotkey = hexSettings.hotkey

        // Notes mode (docs/hotkey-semantics.md): while a session records, any clean press stops it. Otherwise
        // a quick clean tap starts one, and every other press is an ordinary dictation: the processor gets
        // the same events, so a hold records from key-down.
        if case let .keyboard(keyEvent) = inputEvent, isNotesRecording || hexSettings.rewriteMode == .notes {
          let wasHeld = notesTaps.isHeld
          if !wasHeld { notesPressBeganIdle = hotKeyProcessor.state == .idle }
          let output = notesTaps.process(keyEvent)
          // A key hotkey's own key is swallowed, as it is for dictation.
          let swallow = keyEvent.key != nil && keyEvent.key == hexSettings.hotkey.key && (wasHeld || notesTaps.isHeld)
          if isNotesRecording {
            switch output {
            case .tapped, .released:
              Task { await send(.notesTapped) }
            case .escape:
              Task { await send(.cancel) }
            case nil:
              break
            }
            return swallow
          }
          // Only a press that began with nothing recording: the press that stops a locked dictation isn't a tap.
          if output == .tapped, notesPressBeganIdle {
            // The recording this press started is dropped; the processor forgets the press (no lock later).
            hotKeyProcessor.abandonPress()
            Task { await send(.notesTapped) }
            return swallow
          }
        }

        switch inputEvent {
        case .keyboard(let keyEvent):
          // If Escape is pressed with no modifiers while idle, let's treat that as `cancel`.
          if keyEvent.key == .escape, keyEvent.modifiers.isEmpty,
             hotKeyProcessor.state == .idle
          {
            Task { await send(.cancel) }
            return false
          }

          // While the last dictation is still processing, a press is ignored (`.hotKeyPressed`). Keeping it
          // from the processor too stops a stray tap from counting as half of a double-tap lock.
          if inFlight.isProcessing, hotKeyProcessor.state == .idle {
            return keyEvent.key != nil && keyEvent.key == hexSettings.hotkey.key
              && keyEvent.modifiers == hexSettings.hotkey.modifiers
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

  /// Capture problems, and a session nobody is talking in, reported while a notes session records.
  func startNotesEventsEffect() -> Effect<Action> {
    .run { send in
      for await event in notes.events() {
        switch event {
        case let .captureFailed(message): await send(.notesCaptureFailed(message))
        case .silenceLimitReached: await send(.notesSilent)
        case .discardedSilent: await send(.notesDiscardedSilent)
        case .changed: break
        }
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
  func handleHotKeyReleased(isRecording: Bool) -> Effect<Action> {
    // Always stop recording when hotkey is released
    return isRecording ? .send(.stopRecording) : .none
  }
}

// MARK: - Notes Handlers

private extension TranscriptionFeature {
  func handleNotesStart(_ state: inout State) -> Effect<Action> {
    state.notesRecording = NotesRecording(startedAt: now)
    state.$isNotesRecording.withLock { $0 = true }
    state.caption = nil
    transcriptionFeatureLogger.notice("Notes session requested")
    return .merge(
      .cancel(id: CancelID.liveCaption),
      .run { [notes, sleepManagement] send in
        soundEffect.play(.startRecording)
        // Hands-free for up to 2 h: idle sleep would end it.
        await sleepManagement.preventSleep(reason: "LegacyScribe notes session")
        do {
          await send(.notesStarted(try await notes.start()))
        } catch {
          transcriptionFeatureLogger.error("Notes session failed to start: \(error.localizedDescription, privacy: .public)")
          await send(.notesStartFailed(error.localizedDescription))
        }
      },
      .run { [notes] send in
        for await meter in notes.meters() {
          await send(.audioLevelUpdated(meter))
        }
      }
      .cancellable(id: CancelID.notesMetering, cancelInFlight: true),
      .run { send in
        try await Task.sleep(for: .seconds(NotesSession.maxDuration - NotesSession.warningLead))
        await send(.notesWarn)
        try await Task.sleep(for: .seconds(NotesSession.warningLead))
        await send(.notesStop)
      }
      .cancellable(id: CancelID.notesTimer, cancelInFlight: true)
    )
  }

  /// Stops capture and keeps the session; its transcript and notes are finished in the background. A
  /// session stopped sooner than `seconds` after it started was a mistake: it's deleted, not listed.
  func handleNotesStop(
    _ state: inout State, discardingUnder seconds: TimeInterval = NotesSession.stopDiscardSeconds
  ) -> Effect<Action> {
    guard let session = state.notesRecording else { return .none }
    guard session.id != nil else {
      // Still starting: stop as soon as capture is up.
      state.notesRecording?.stopRequested = true
      return .none
    }
    let discard = now.timeIntervalSince(session.startedAt) < seconds
    state.notesRecording = nil
    state.$isNotesRecording.withLock { $0 = false }
    state.meter = .init(averagePower: 0, peakPower: 0)
    state.showNotice(discard ? .notesDiscarded(silent: false) : .notesSaved)
    return .merge(
      .cancel(id: CancelID.notesMetering),
      .cancel(id: CancelID.notesTimer),
      .run { [notes, sleepManagement] _ in
        if discard {
          await notes.discard()
          soundEffect.play(.cancel)
        } else {
          await notes.stop()
          soundEffect.play(.stopRecording)
        }
        await sleepManagement.allowSleep()
      }
    )
  }
}

struct NotesRecording: Equatable {
  /// Nil until capture is running.
  var id: String?
  var startedAt: Date
  /// A stop that came while the session was still starting.
  var stopRequested = false
}

/// A dictation cancelled with Esc (while recording or transcribing), kept so Undo can finish it.
struct CancelledDictation: Equatable, Sendable {
  /// Shorter recordings aren't offered: a cancel that quick was meant.
  static let minimumDuration: TimeInterval = 1

  var id = UUID()
  var audioURL: URL
  var duration: TimeInterval
  var sourceAppBundleID: String?
  var sourceAppName: String?
  var biasing: BiasingContext
}

/// What the reducer shares with long-running effects. The transcription holds its recording here until
/// it hands the result on; a cancel takes it first, so the transcription doesn't delete it. The hotkey
/// monitor reads `isProcessing`. A reference, so the copy in `State` and the effects' copies are the same.
final class DictationInFlight: Equatable, @unchecked Sendable {
  private let lock = NSLock()
  private var audio: (url: URL, duration: TimeInterval)?
  private var processing = false

  var isProcessing: Bool {
    get { lock.withLock { processing } }
    set { lock.withLock { processing = newValue } }
  }

  func holdAudio(_ url: URL, duration: TimeInterval) {
    lock.withLock { audio = (url, duration) }
  }

  /// Ends the hold. False when a cancel took the recording (it's no longer the holder's to delete).
  func releaseAudio(_ url: URL) -> Bool {
    lock.withLock {
      guard audio?.url == url else { return false }
      audio = nil
      return true
    }
  }

  /// Takes the recording away from the transcription.
  func takeAudio() -> (url: URL, duration: TimeInterval)? {
    lock.withLock {
      defer { audio = nil }
      return audio
    }
  }

  static func == (lhs: DictationInFlight, rhs: DictationInFlight) -> Bool { lhs === rhs }
}

struct NoticeRequest: Equatable {
  var notice: DictationNotice
  var serial: Int
}

extension TranscriptionFeature.State {
  mutating func showNotice(_ notice: DictationNotice) {
    self.notice = NoticeRequest(notice: notice, serial: (self.notice?.serial ?? 0) + 1)
  }
}

extension SharedReaderKey
  where Self == InMemoryKey<Bool>.Default
{
  /// True while a notes session records; the hotkey monitor then sends the talk key to it.
  static var isNotesRecording: Self {
    Self[.inMemory("isNotesRecording"), default: false]
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
    state.$isPlacingCaption.withLock { $0 = false }
    state.notesHold = false
    let startTime = now
    state.recordingStartTime = startTime
    // In Notes mode a quick tap starts a session (with its own sound) instead, so this one waits out the tap.
    let inNotesMode = state.hexSettings.rewriteMode == .notes
    
    // Capture the active application
    if let activeApp = NSWorkspace.shared.frontmostApplication {
      state.sourceAppBundleID = activeApp.bundleIdentifier
      state.sourceAppName = activeApp.localizedName
    }
    state.fieldContext = nil
    transcriptionFeatureLogger.notice("Recording started at \(startTime.ISO8601Format())")

    // Prevent system sleep during recording
    return .merge(
      .cancel(id: CancelID.recordingCleanup),
      // The text around the cursor, read before focus can move: its names become spelling hints, and a
      // Legacy dictation edits the selection.
      .run { [focusedText, enabled = state.hexSettings.contextTermsEnabled || state.hexSettings.superEnabled] send in
        guard enabled, let field = focusedText.read() else { return }
        await send(.fieldContextCaptured(field))
      },
      // Legacy shows about a second after "legacy" is said: Apple Speech peeks at the start of the dictation.
      .run { [speechPeek, recording, enabled = state.hexSettings.superEnabled && state.hexSettings.superEarlyDetection] send in
        guard enabled, await speechPeek.isAvailable() else { return }
        let started = ContinuousClock.now
        for offset in SuperTrigger.peekSeconds {
          try await Task.sleep(until: started + .seconds(offset), clock: .continuous)
          let head = await recording.recordingHead()
          guard !head.isEmpty else { continue }
          guard let text = await speechPeek.transcribe(head) else { return }
          let verdict = SuperTrigger.earlyVerdict(text)
          if let isSuper = verdict.isSuper { await send(.superHeard(isSuper)) }
          if verdict.isSettled { return }
        }
      }
      .cancellable(id: CancelID.superPeek, cancelInFlight: true),
      .run { [clock] send in
        guard inNotesMode else { return }
        try await clock.sleep(for: .seconds(NotesTapDetector.tapWindow))
        await send(.notesHoldConfirmed)
      }
      .cancellable(id: CancelID.notesHold, cancelInFlight: true),
      .run { [sleepManagement, preventSleep = state.hexSettings.preventSystemSleep] send in
        // Play sound immediately for instant feedback
        if !inNotesMode { soundEffect.play(.startRecording) }

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
        await send(.microphoneReady)
      }
      .cancellable(id: CancelID.recordingStart, cancelInFlight: true)
    )
  }

  /// Model loads wait for the microphone so they can't slow down arming it; they still have the whole
  /// dictation to finish (~0.4–1.3 s for Cohere), and a dictation that ends first loads the model itself.
  func handleMicrophoneReady(_ state: State) -> Effect<Action> {
    guard state.isRecording else { return .none }
    return .merge(
      // The caption starts only now, so it can't slow down arming the microphone.
      .run { [liveCaption, recording, enabled = state.hexSettings.liveCaptionEnabled] send in
        guard enabled, await liveCaption.isAvailable(), let samples = await recording.recordingSamples() else { return }
        for await text in liveCaption.captions(samples) {
          await send(.captionUpdated(text))
        }
      }
      .cancellable(id: CancelID.liveCaption, cancelInFlight: true),
      .run { [transcription, model = state.hexSettings.selectedModel] _ in
        await transcription.prewarm(model)
      },
      .run { [localLLM, settings = state.hexSettings] _ in
        guard settings.dictationMode.rewrites, settings.rewritePrimary.provider == .onDevice else { return }
        await localLLM.prewarm(settings.rewritePrimary.model)
      }
    )
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    // Key-up: the caption goes with the recording; the real engine's text is what gets pasted and kept.
    state.caption = nil
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

    let field = state.hexSettings.contextTermsEnabled ? state.fieldContext : nil
    state.superField = state.hexSettings.superEnabled ? state.fieldContext : nil
    state.biasing = biasingContext(field: field, settings: state.hexSettings)
    state.fieldContext = nil
    if !state.biasing.isEmpty {
      let (vocabulary, fixed, nearby) = (state.biasing.vocabulary.count, state.biasing.corrections.count, state.biasing.nearby.count)
      HexLog.rewrite.info("Spelling hints: \(vocabulary) vocabulary, \(fixed) fixed, \(nearby) nearby")
    }

    // Otherwise, proceed to transcription
    state.isTranscribing = true
    state.error = nil
    state.isPrewarming = true

    return .merge(
      .cancel(id: CancelID.liveCaption),
      .cancel(id: CancelID.recordingStart),
      .cancel(id: CancelID.superPeek),
      .cancel(id: CancelID.notesHold),
      transcribeEffect(
        recording: nil, duration: duration, keyUp: keyUp,
        model: model, language: state.hexSettings.outputLanguage, inFlight: state.inFlight
      )
    )
  }

  /// The vocabulary, spellings fixed in sent text, and names near the cursor (`field`) for one dictation.
  func biasingContext(field: FocusedText?, settings: HexSettings) -> BiasingContext {
    @Shared(.sentEdits) var sentEdits: SentEditLog
    return BiasingContext.build(
      vocabulary: settings.vocabulary,
      sentEdits: sentEdits.edits,
      field: field.map { (text: $0.value, cursor: $0.cursor) }
    )
  }

  /// Transcribes a dictation and sends `.transcriptionResult`. With `recording` nil the microphone is stopped
  /// and its capture used; Undo passes the recording a cancel kept. While this runs the recording is held in
  /// `inFlight`: a cancel takes it from there for Undo, and whatever nobody took is deleted at the end.
  func transcribeEffect(
    recording kept: URL?,
    duration: TimeInterval,
    keyUp: ContinuousClock.Instant,
    model: String,
    language: String?,
    inFlight: DictationInFlight
  ) -> Effect<Action> {
    .run { [sleepManagement] send in
      if kept == nil {
        // Allow system to sleep again
        await sleepManagement.allowSleep()
      }

      var timeline = DictationTimeline(keyUp: keyUp)
      var audioURL: URL?
      defer {
        if let audioURL, inFlight.releaseAudio(audioURL) {
          FileManager.default.removeItemIfExists(at: audioURL)
        }
      }
      do {
        let capturedURL: URL
        if let kept {
          capturedURL = kept
        } else {
          switch await recording.stopRecording() {
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
        }
        audioURL = capturedURL
        inFlight.holdAudio(capturedURL, duration: duration)
        timeline.captureStopped = stampLatency("captureStopped")
        guard !Task.isCancelled else { return }
        if kept == nil {
          soundEffect.play(.stopRecording)
        }

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
        // A cancel that came during the transcription took the recording for Undo.
        guard inFlight.releaseAudio(capturedURL) else { return }
        await send(.transcriptionResult(result, capturedURL, duration, timeline))
      } catch {
        transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription)")
        // Esc cancels the dictation (its recording is kept for Undo); any other failure keeps it for Retry.
        if !Task.isCancelled, !(error is CancellationError), let failed = audioURL, inFlight.releaseAudio(failed) {
          audioURL = nil
          await send(.transcriptionFailed(error, failed, duration))
        } else {
          await send(.transcriptionError(error, nil))
        }
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  /// Undo: the cancelled dictation goes through transcription and the rewrite again, for the app it was
  /// dictated into. Context read at key-down (a Legacy selection, a merge) isn't restored.
  func handleUndo(_ state: inout State, _ kept: CancelledDictation) -> Effect<Action> {
    state.isTranscribing = true
    state.error = nil
    state.sourceAppBundleID = kept.sourceAppBundleID
    state.sourceAppName = kept.sourceAppName
    state.biasing = kept.biasing
    state.superField = nil
    state.undone = kept
    transcriptionFeatureLogger.notice("Undo: transcribing the cancelled dictation again")
    return transcribeEffect(
      recording: kept.audioURL, duration: kept.duration, keyUp: stampLatency("keyUp"),
      model: state.hexSettings.selectedModel, language: state.hexSettings.outputLanguage, inFlight: state.inFlight
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
    // The early look ends here; a Legacy transcript turns it back on below.
    state.superActive = false
    let isUndo = state.undone != nil
    state.undone = nil

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
    let superField = state.superField
    state.superField = nil
    if state.hexSettings.superEnabled, !state.isRemappingScratchpadFocused,
       let instruction = SuperTrigger.instruction(in: result) {
      return handleSuper(
        &state, instruction: instruction, recognized: result, field: superField,
        audioURL: audioURL, duration: duration, timeline: timeline, isUndo: isUndo
      )
    }
    let settings = state.hexSettings
    let skipModifications = state.isRemappingScratchpadFocused
    if skipModifications {
      transcriptionFeatureLogger.info("Scratchpad focused; skipping word modifications and rewrite")
    }

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let biasing = state.biasing
    let transcriptionHistory = state.$transcriptionHistory
    let engine = settings.selectedModel
    // A dictation in Notes mode (held, not tapped) is rewritten in the mode picked before Notes.
    let rewriteMode = skipModifications || !settings.dictationMode.rewrites ? RewriteMode.raw : settings.dictationMode

    return .run { send in
      var timeline = timeline
      var output = skipModifications ? result : rewriter.applyWordModifications(result, settings: settings)
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

      // Merge: a Prompt dictation joins the text already in the field instead of being pasted after it.
      var mergeBase: String?
      if rewriteMode == .prompt, settings.mergeIntoFieldEnabled, leadingCommand == nil, !output.isEmpty,
         let field = focusedText.read(), field.bundleID == sourceAppBundleID {
        mergeBase = FieldMerge.existingText(field.value, bundleID: field.bundleID)
      }
      var replaceField = false

      if rewriteMode != .raw, !output.isEmpty {
        await send(.rewriteStateChanged(true))
        let outcome = await rewriter.rewrite(
          output,
          mode: rewriteMode,
          settings: settings,
          biasing: biasing,
          targetAppName: sourceAppName,
          codeTalkCommands: codeTalkCommands,
          existingText: mergeBase
        )
        await send(.rewriteStateChanged(false))
        timeline.rewritten = stampLatency("rewritten")
        guard !Task.isCancelled else {
          FileManager.default.removeItemIfExists(at: audioURL)
          return
        }
        rewriteOutcome = outcome
        if outcome.rewrittenBy != nil, let mergeBase, !fieldStillHolds(mergeBase) {
          // The field changed while the LLM worked; pasting the merge over it would lose that.
          HexLog.rewrite.notice("Field changed during the merge; pasting the transcript at the cursor")
        } else if outcome.rewrittenBy != nil {
          output = outcome.text
          appliedRewrite = rewriteMode
          replaceField = mergeBase != nil
        } else if !outcome.failures.isEmpty {
          await send(.rewriteFellBack)
        }
      }
      // Like Cohere, the on-device model is loaded per dictation (warmed at key-down) and doesn't stay
      // resident, whether or not this dictation ended up rewritten.
      if settings.rewritePrimary.provider == .onDevice
        || (settings.rewriteFallbackEnabled && settings.rewriteFallback.provider == .onDevice) {
        Task { [localLLM] in await localLLM.unload() }
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

      let paste = undoMayPaste(isUndo, into: sourceAppBundleID)
      do {
        try await finalizeRecordingAndStoreTranscript(
          result: output,
          rawText: appliedRewrite == nil && leadingCommand == nil ? nil : result,
          rewriteMode: appliedRewrite,
          rewriteOutcome: rewriteOutcome,
          recognized: result,
          replaceField: replaceField,
          // A leading slash command must reach the app as typed; the scratchpad takes the text as is.
          matchSurroundings: !skipModifications && leadingCommand == nil,
          knownSpellings: biasing.vocabulary + biasing.corrections + biasing.nearby,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          transcriptionHistory: transcriptionHistory,
          timeline: timeline,
          engine: engine,
          paste: paste,
          watchSent: paste
        )
        if !paste { await send(.undoNotPasted(await keepUnpasted(output, appName: sourceAppName, settings: settings))) }
      } catch {
        await send(.transcriptionError(error, audioURL))
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  /// Undo comes after the user may have moved on, so it pastes only while the dictation's app is in front.
  func undoMayPaste(_ isUndo: Bool, into bundleID: String?) -> Bool {
    guard isUndo else { return true }
    let front = focusedText.frontmostBundleID()
    return front != nil && front == bundleID
  }

  /// An Undo that couldn't paste: the text is in History, or on the clipboard when History is off.
  func keepUnpasted(_ text: String, appName: String?, settings: HexSettings) async -> DictationNotice {
    if settings.saveTranscriptionHistory { return .undoSaved(appName) }
    await pasteboard.copy(text)
    return .undoCopied(appName)
  }

  /// A dictation that started with "legacy": the rest is an instruction that edits the text selected at
  /// key-down, or writes at the cursor with the field around it as context. When it fails nothing in the
  /// field changes: the dictation is copied and kept in History.
  func handleSuper(
    _ state: inout State,
    instruction: String,
    recognized: String,
    field: FocusedText?,
    audioURL: URL,
    duration: TimeInterval,
    timeline: DictationTimeline,
    isUndo: Bool = false
  ) -> Effect<Action> {
    guard !instruction.isEmpty else {
      transcriptionFeatureLogger.notice("Legacy heard with no instruction after it; nothing to do")
      state.showNotice(.superFailed("Say what to do after \u{201C}legacy\u{201D}"))
      return .run { _ in FileManager.default.removeItemIfExists(at: audioURL) }
    }
    state.superActive = true
    let settings = state.hexSettings
    let (sourceAppBundleID, sourceAppName) = (state.sourceAppBundleID, state.sourceAppName)
    let biasing = state.biasing
    let transcriptionHistory = state.$transcriptionHistory
    let engine = settings.selectedModel

    // Terminals report their scrollback as the field, so Legacy only writes there, without context.
    var request = SuperRequest.write(before: "", after: "")
    var problem: String?
    if let field, field.bundleID == sourceAppBundleID,
       !(field.bundleID.map(FieldMerge.terminalBundleIDs.contains) ?? false) {
      if field.selectionLength > 0, let selected = field.selectedText,
         !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if let selection = SuperPrompt.editableSelection(selected) {
          request = .edit(selection: selection)
        } else {
          problem = "Legacy failed: selection over \(SuperPrompt.maxSelectionCharacters.formatted()) characters"
        }
      } else if field.selectionLength > 0, field.selectedText == nil {
        // A paste would replace a selection we can't see.
        problem = "Legacy failed: couldn\u{2019}t read the selection"
      } else if let surroundings = field.surroundings {
        request = .write(before: surroundings.before, after: surroundings.after)
      }
    }
    let isEdit = if case .edit = request { true } else { false }
    HexLog.rewrite.info("Legacy \(isEdit ? "edit" : "write", privacy: .public) in \(sourceAppBundleID ?? "unknown app", privacy: .public)")

    return .run { send in
      var timeline = timeline
      var outcome: RewriteOutcome?
      var failure = problem
      if failure == nil {
        let instruction = rewriter.applyWordModifications(instruction, settings: settings)
        await send(.rewriteStateChanged(true))
        let answer = await rewriter.superRewrite(
          instruction, request: request, settings: settings, biasing: biasing, targetAppName: sourceAppName
        )
        await send(.rewriteStateChanged(false))
        timeline.rewritten = stampLatency("rewritten")
        if settings.rewritePrimary.provider == .onDevice
          || (settings.rewriteFallbackEnabled && settings.rewriteFallback.provider == .onDevice) {
          Task { [localLLM] in await localLLM.unload() }
        }
        guard !Task.isCancelled else {
          FileManager.default.removeItemIfExists(at: audioURL)
          return
        }
        outcome = answer
        if answer.rewrittenBy == nil {
          failure = answer.failures.isEmpty ? "Legacy needs an AI: set one up in AI Rewrite" : "Legacy failed: nothing changed"
        } else if case let .edit(selection) = request, !selectionStillHolds(selection, in: field) {
          HexLog.rewrite.notice("The selection changed while Legacy worked; nothing pasted")
          failure = "Legacy stopped: the selection changed"
        }
      }

      if let failure {
        await pasteboard.copy(recognized)
      }
      let paste = failure == nil && undoMayPaste(isUndo, into: sourceAppBundleID)
      do {
        try await finalizeRecordingAndStoreTranscript(
          result: failure == nil ? outcome?.text ?? recognized : recognized,
          rawText: failure == nil ? recognized : nil,
          rewriteMode: nil,
          rewriteOutcome: outcome,
          recognized: recognized,
          replaceField: false,
          // An edit replaces the selection as is; new text fits in like any dictation.
          matchSurroundings: !isEdit,
          knownSpellings: biasing.vocabulary + biasing.corrections + biasing.nearby,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          transcriptionHistory: transcriptionHistory,
          timeline: timeline,
          engine: engine,
          paste: paste,
          // The answer isn't what the speaker said, so what's sent after it isn't a correction of it.
          watchSent: false
        )
        if failure == nil, !paste, let text = outcome?.text {
          await send(.undoNotPasted(await keepUnpasted(text, appName: sourceAppName, settings: settings)))
        }
      } catch {
        await send(.transcriptionError(error, audioURL))
      }
      await send(.superFinished(failure.map(DictationNotice.superFailed)))
    }
    .cancellable(id: CancelID.transcription)
  }

  /// True when the field still has `selection` selected where it was at key-down, so a paste replaces it.
  func selectionStillHolds(_ selection: String, in field: FocusedText?) -> Bool {
    guard let field, let current = focusedText.read() else { return false }
    return current.bundleID == field.bundleID && current.cursor == field.cursor
      && current.selectionLength == field.selectionLength && current.selectedText == selection
  }

  func handleTranscriptionError(
    _ state: inout State,
    error: Error,
    audioURL: URL?
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.superActive = false
    state.error = error.localizedDescription
    
    if let audioURL {
      FileManager.default.removeItemIfExists(at: audioURL)
    }

    return .none
  }

  /// URL actions reuse the hotkey's paths. `stop` and `toggle` end whatever is recording, a dictation or a
  /// notes session; `start` and `toggle` start a dictation (in Notes mode it pastes as recognized).
  func handleURLAction(_ state: inout State, _ action: URLAction) -> Effect<Action> {
    guard state.hexSettings.urlActionsEnabled || !action.canStartRecording else {
      transcriptionFeatureLogger.notice("Ignored a URL action that starts recording: URL actions are off in Settings")
      return .none
    }
    let busy = state.isRecording || state.notesRecording != nil
    switch action {
    case .start:
      guard !busy, !state.isTranscribing else { return .none }
      return handleStartRecording(&state)
    case .stop:
      if state.isRecording { return handleStopRecording(&state) }
      return state.notesRecording != nil ? handleNotesStop(&state) : .none
    case .toggle:
      if busy { return handleURLAction(&state, .stop) }
      return handleURLAction(&state, .start)
    case .cancel:
      return .send(.cancel)
    case let .mode(mode):
      state.$hexSettings.withLock { $0.rewriteMode = mode }
      return .none
    case .notesStart:
      guard !busy else { return .none }
      return handleNotesStart(&state)
    case .notesStop:
      return state.notesRecording != nil ? handleNotesStop(&state) : .none
    }
  }

  /// Keeps a recording the engine couldn't transcribe as a History entry with no text and the reason, so
  /// it can be retried. Nothing is pasted.
  func handleTranscriptionFailed(
    _ state: inout State,
    error: Error,
    audioURL: URL,
    duration: TimeInterval
  ) -> Effect<Action> {
    let cleanup = handleTranscriptionError(&state, error: error, audioURL: nil)
    guard state.hexSettings.saveTranscriptionHistory else {
      FileManager.default.removeItemIfExists(at: audioURL)
      return cleanup
    }
    let reason = error.localizedDescription
    let (bundleID, appName) = (state.sourceAppBundleID, state.sourceAppName)
    let history = state.$transcriptionHistory
    return .merge(
      cleanup,
      .run { [transcriptPersistence] send in
        do {
          var transcript = try await transcriptPersistence.save("", audioURL, duration, bundleID, appName)
          transcript.failure = reason
          history.withLock { $0.history.insert(transcript, at: 0) }
          transcriptionFeatureLogger.notice("Kept the failed recording in History for Retry")
          let id = transcript.id
          Task.detached(priority: .utility) { AudioRetentionSweep.compress(ids: [id]) }
          await send(.failedDictationKept)
        } catch {
          transcriptionFeatureLogger.error("Couldn't keep the failed recording: \(error.localizedDescription)")
          FileManager.default.removeItemIfExists(at: audioURL)
        }
      }
    )
  }

  /// Move file to permanent location, create a transcript record, paste text, and play sound.
  func finalizeRecordingAndStoreTranscript(
    result: String,
    rawText: String?,
    rewriteMode: RewriteMode?,
    rewriteOutcome: RewriteOutcome?,
    recognized: String,
    replaceField: Bool,
    matchSurroundings: Bool,
    knownSpellings: [String],
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
    audioURL: URL,
    transcriptionHistory: Shared<TranscriptionHistory>,
    timeline: DictationTimeline,
    engine: String,
    paste: Bool = true,
    watchSent: Bool = true
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
    guard paste else {
      if let savedTranscriptID {
        Task.detached(priority: .utility) { AudioRetentionSweep.compress(ids: [savedTranscriptID]) }
      }
      return
    }

    // A merge replaces the whole field, so there's nothing around it to match.
    let adjustInsertion = hexSettings.matchSurroundingText && matchSurroundings && !replaceField
    let captureSent = hexSettings.captureSentEdits && watchSent
    let fieldBeforePaste = captureSent || adjustInsertion ? focusedText.read() : nil
    // History keeps the text as written; the paste (and the sent-text capture) use the fitted version.
    var pasted = result
    if adjustInsertion {
      // Says why nothing changed, without the text: Accessibility differs a lot between apps.
      let field = fieldBeforePaste
      let app = field?.bundleID ?? "unknown app"
      if let field, let bundleID = field.bundleID, !FieldMerge.terminalBundleIDs.contains(bundleID),
         let surroundings = field.surroundings {
        pasted = InsertionAdjuster.adjust(
          result, before: surroundings.before, after: surroundings.after, keepCapitalized: knownSpellings
        )
        transcriptionFeatureLogger.info(
          "Surrounding text in \(app, privacy: .public): \(surroundings.before.count) chars before, \(surroundings.after.count) after; paste \(pasted == result ? "unchanged" : "adjusted", privacy: .public)"
        )
      } else if let field {
        let reason = field.bundleID.map { FieldMerge.terminalBundleIDs.contains($0) } == true ? "terminal"
          : field.cursor == nil ? "app reports no cursor" : "cursor outside the field's text"
        transcriptionFeatureLogger.info(
          "Surrounding text skipped in \(app, privacy: .public): \(reason, privacy: .public) (value \(field.value.utf16.count) units, cursor \(field.cursor ?? -1), selection \(field.selectionLength))"
        )
      } else {
        transcriptionFeatureLogger.info("Surrounding text skipped: no readable text field is focused (or Accessibility isn't granted)")
      }
    }
    if replaceField {
      // Select the field's text so the merged version replaces it (⌘Z in the app undoes this).
      await pasteboard.sendKeyboardCommand(KeyboardCommand(key: .a, modifiers: [.command]))
    }
    await pasteboard.paste(pasted)
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

    if let savedTranscriptID {
      // Kept as FLAC, a quarter of the size; off the hot path, the text is already pasted.
      Task.detached(priority: .utility) { AudioRetentionSweep.compress(ids: [savedTranscriptID]) }
    }

    if captureSent, let fieldBeforePaste {
      await watchForSend(
        fieldBefore: fieldBeforePaste,
        pasted: pasted,
        recognized: recognized,
        mode: rewriteMode,
        transcriptID: savedTranscriptID,
        appName: sourceAppName
      )
    }
  }

  /// True when the focused field still holds `text` (trimmed), so it can be replaced safely.
  func fieldStillHolds(_ text: String) -> Bool {
    focusedText.read()?.value.trimmingCharacters(in: .whitespacesAndNewlines) == text
  }

  /// Waits for the paste to land, then remembers the field so Enter can capture the sent version.
  func watchForSend(
    fieldBefore: FocusedText,
    pasted: String,
    recognized: String,
    mode: RewriteMode?,
    transcriptID: UUID?,
    appName: String?
  ) async {
    guard let bundleID = fieldBefore.bundleID, !FieldMerge.terminalBundleIDs.contains(bundleID) else { return }
    var fieldAfter: FocusedText?
    for _ in 0 ..< 10 {
      try? await Task.sleep(for: .milliseconds(100))
      guard !Task.isCancelled else { return }
      fieldAfter = focusedText.read()
      if let fieldAfter, fieldAfter.value != fieldBefore.value { break }
    }
    guard let fieldAfter, fieldAfter.bundleID == bundleID, fieldAfter.value != fieldBefore.value else {
      HexLog.learning.info("Paste not visible in the focused field of \(bundleID, privacy: .public); not watching for Enter")
      return
    }
    @Shared(.pendingSentEdit) var pendingSentEdit: PendingSentEdit?
    $pendingSentEdit.withLock {
      $0 = PendingSentEdit(
        startedAt: now,
        transcriptID: transcriptID,
        bundleID: bundleID,
        appName: appName,
        mode: mode,
        recognized: recognized,
        pasted: pasted,
        fieldBefore: fieldBefore.value,
        fieldAfterPaste: fieldAfter.value
      )
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
    // Undo needs the app the dictation was for and its spelling hints; a recording too short to be a
    // dictation isn't worth an offer.
    let undoSeconds = state.hexSettings.cancelUndoSeconds
    let field = state.hexSettings.contextTermsEnabled ? state.fieldContext : nil
    let biasing = wasRecording ? biasingContext(field: field, settings: state.hexSettings) : state.biasing
    let (bundleID, appName) = (state.sourceAppBundleID, state.sourceAppName)
    let keepForUndo: @Sendable (URL, TimeInterval) -> CancelledDictation? = { url, duration in
      guard undoSeconds > 0, duration >= CancelledDictation.minimumDuration else { return nil }
      return CancelledDictation(
        audioURL: url, duration: duration, sourceAppBundleID: bundleID, sourceAppName: appName, biasing: biasing
      )
    }
    let recordedFor = state.recordingStartTime.map { now.timeIntervalSince($0) } ?? 0
    // Cancelled mid-transcription: the recording is taken from the transcription so it isn't deleted.
    var keptWhileTranscribing: CancelledDictation?
    var dropped: URL?
    if !wasRecording, let audio = state.inFlight.takeAudio() {
      keptWhileTranscribing = keepForUndo(audio.url, audio.duration)
      if keptWhileTranscribing == nil { dropped = audio.url }
    }
    state.undone = nil
    state.isTranscribing = false
    state.isRecording = false
    state.isPrewarming = false
    state.isRewriting = false
    state.superActive = false
    state.superField = nil
    state.caption = nil

    return .merge(
      .cancel(id: CancelID.liveCaption),
      .cancel(id: CancelID.transcription),
      .cancel(id: CancelID.recordingStart),
      .cancel(id: CancelID.superPeek),
      .cancel(id: CancelID.notesHold),
      .run { [sleepManagement, localLLM] send in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        // The rewrite model warmed at key-down isn't needed now.
        await localLLM.unload()
        if let dropped { FileManager.default.removeItemIfExists(at: dropped) }
        guard wasRecording else {
          soundEffect.play(.cancel)
          return
        }
        // Stop the recording to release microphone access; it's kept for Undo unless a new one already started.
        let result = await recording.stopRecording()
        if case let .captured(url) = result {
          if !Task.isCancelled, let kept = keepForUndo(url, recordedFor) {
            await send(.cancelKept(kept))
          } else {
            FileManager.default.removeItemIfExists(at: url)
          }
        }
        guard !Task.isCancelled else { return }
        soundEffect.play(.cancel)
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true),
      keptWhileTranscribing.map { .send(.cancelKept($0)) } ?? .none
    )
  }

  func handleDiscard(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.isPrewarming = false
    state.superActive = false
    state.caption = nil

    // Silently discard - no sound effect
    return .merge(
      .cancel(id: CancelID.liveCaption),
      .cancel(id: CancelID.recordingStart),
      .cancel(id: CancelID.superPeek),
      .cancel(id: CancelID.notesHold),
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
  /// The live caption's measured size, for placing it by its centre.
  @State private var captionSize = CGSize(width: 364, height: 44)
  /// While the sample caption is dragged: where it started, and the spot it has reached.
  @State private var dragStart: CGPoint?
  @State private var dragSpot: CaptionSpot?
  @Shared(.hexSettings) private var hexSettings: HexSettings
  @Shared(.isPlacingCaption) private var isPlacingCaption: Bool
  private let screen = VisibleScreen.shared

  var status: TranscriptionIndicatorView.Status {
    if store.notesRecording != nil {
      return .recording
    } else if store.isTranscribing {
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

  /// A one-off notice wins, then Legacy; otherwise a non-Clean mode is tagged while recording.
  private var visibleNotice: DictationNotice? {
    if let notice { return notice }
    if store.superActive { return .superOn }
    if let notes = store.notesRecording { return .notesRecording(since: notes.startedAt) }
    // Undo waits out a new dictation and comes back after it.
    if store.cancelled != nil, !store.isRecording, !store.isProcessing { return .cancelled }
    guard store.isRecording else { return nil }
    if store.hexSettings.rewriteMode == .notes {
      // Hidden for the tap window: a quick tap becomes a session with its own pill.
      return store.notesHold ? .notesDictating(store.hexSettings.dictationMode) : nil
    }
    let mode = store.hexSettings.rewriteMode
    if store.hexSettings.privateMode { return .recordingPrivate(mode) }
    return mode != .clean ? .recordingIn(mode) : nil
  }

  /// The indicator, its notice and (placement "under the indicator") the caption, stacked from the top.
  private var indicatorColumn: some View {
    VStack(spacing: 8) {
      TranscriptionIndicatorView(
        status: status,
        meter: store.meter,
        isSuper: store.superActive
      )
      ZStack {
        if let cyclerHighlight {
          ModeCyclerBarView(highlight: cyclerHighlight)
            .transition(DictationNoticeView.transition(reduceMotion: reduceMotion))
        } else if let visibleNotice {
          DictationNoticeView(notice: visibleNotice, onUndo: { store.send(.undoCancel) })
            .background {
              // The window is click-through except over the Undo pill.
              if visibleNotice == .cancelled {
                GeometryReader { proxy in
                  Color.clear
                    .onAppear { InvisibleWindow.shared?.clickableRect = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in
                      InvisibleWindow.shared?.clickableRect = frame
                    }
                    .onDisappear { InvisibleWindow.shared?.clickableRect = nil }
                }
              }
            }
            .transition(DictationNoticeView.transition(reduceMotion: reduceMotion))
        }
      }
      .animation(DictationNoticeView.entrance, value: cyclerHighlight == nil)
      // Only appearing and disappearing animate; a notice replacing another swaps in place.
      .animation(
        visibleNotice == nil ? DictationNoticeView.exit : DictationNoticeView.entrance,
        value: visibleNotice == nil
      )
      if captionPlacement == .underIndicator {
        ZStack {
          if let caption = store.caption, !caption.isEmpty {
            LiveCaptionView(caption: caption)
              .transition(DictationNoticeView.transition(reduceMotion: reduceMotion))
          }
        }
        .animation(store.caption?.isEmpty ?? true ? DictationNoticeView.exit : DictationNoticeView.entrance, value: store.caption?.isEmpty ?? true)
      }
    }
  }

  /// Bottom of the screen and "where I put it": the caption is placed in the window by `CaptionLayout`, off the
  /// indicator column. In placing mode a draggable sample takes its place.
  private var floatingCaptionLayer: some View {
    GeometryReader { proxy in
      let origin = proxy.frame(in: .global).origin
      let visible = screen.visibleRect
      if showsPlacingSample {
        placingSample(visible: visible, origin: origin)
          .transition(DictationNoticeView.transition(reduceMotion: reduceMotion))
      } else {
        let center = CaptionLayout.center(
          placement: captionPlacement,
          spot: store.hexSettings.liveCaptionSpot,
          visible: visible,
          caption: captionSize
        ) ?? CGPoint(x: visible.midX, y: visible.maxY - 24 - captionSize.height / 2)
        ZStack {
          if let caption = store.caption, !caption.isEmpty {
            LiveCaptionView(caption: caption)
              .onGeometryChange(for: CGSize.self, of: \.size) { captionSize = $0 }
              .transition(DictationNoticeView.transition(reduceMotion: reduceMotion))
          }
        }
        .animation(store.caption?.isEmpty ?? true ? DictationNoticeView.exit : DictationNoticeView.entrance, value: store.caption?.isEmpty ?? true)
        .position(x: center.x - origin.x, y: center.y - origin.y)
      }
    }
    .animation(showsPlacingSample ? DictationNoticeView.entrance : DictationNoticeView.exit, value: showsPlacingSample)
  }

  /// A live caption at its biggest (two full lines), the size placing mode clamps with, so a spot dragged to an
  /// edge keeps every later caption inside the screen.
  private static let placingCaptionSize = CGSize(width: 364, height: 44)

  private func placingSample(visible: CGRect, origin: CGPoint) -> some View {
    let spot = dragSpot ?? store.hexSettings.liveCaptionSpot ?? CaptionLayout.defaultSpot
    let center = CaptionLayout.center(
      placement: .custom,
      spot: spot,
      visible: visible,
      caption: Self.placingCaptionSize
    ) ?? .zero
    let barAbove = spot.y > 0.75
    let shift = (CaptionPlacingView.barHeight + CaptionPlacingView.barGap) / 2 * (barAbove ? -1 : 1)
    return CaptionPlacingView(
      barAbove: barAbove,
      onReset: { $hexSettings.withLock { $0.liveCaptionSpot = CaptionLayout.defaultSpot } },
      onDone: { $isPlacingCaption.withLock { $0 = false } }
    )
    .background {
      // The window is click-through except over the sample and its bar.
      GeometryReader { proxy in
        Color.clear
          .onAppear { InvisibleWindow.shared?.clickableRect = proxy.frame(in: .global) }
          .onChange(of: proxy.frame(in: .global)) { _, frame in
            InvisibleWindow.shared?.clickableRect = frame
          }
          .onDisappear { InvisibleWindow.shared?.clickableRect = nil }
      }
    }
    .position(x: center.x - origin.x, y: center.y + shift - origin.y)
    .gesture(
      DragGesture(minimumDistance: 2, coordinateSpace: .global)
        .onChanged { drag in
          let start = dragStart ?? center
          dragStart = start
          let target = CGPoint(x: start.x + drag.translation.width, y: start.y + drag.translation.height)
          dragSpot = CaptionSpot(
            x: min(max((target.x - visible.minX) / visible.width, 0), 1),
            y: min(max((target.y - visible.minY) / visible.height, 0), 1)
          )
        }
        .onEnded { _ in
          if let dragSpot { $hexSettings.withLock { $0.liveCaptionSpot = dragSpot } }
          dragSpot = nil
          dragStart = nil
        }
    )
  }

  private var captionPlacement: CaptionPlacement { store.hexSettings.liveCaptionPlacement }

  /// The sample caption shows only between dictations: never while recording or processing.
  private var showsPlacingSample: Bool {
    store.isPlacingCaption && !store.isRecording && !store.isProcessing
  }

  var body: some View {
    ZStack(alignment: .top) {
      indicatorColumn
      if captionPlacement != .underIndicator || showsPlacingSample {
        floatingCaptionLayer
      }
    }
    .onChange(of: store.hexSettings.rewriteMode) { _, mode in
      show(.modeChanged(mode))
    }
    .onChange(of: store.rewriteFallbackCount) { _, _ in
      show(.rewriteFellBack)
    }
    .onChange(of: store.notice) { _, request in
      if let request { show(request.notice) }
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
