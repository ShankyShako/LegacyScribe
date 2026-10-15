import ComposableArchitecture
import Foundation
import HexCore
import XCTest

@testable import Hex

/// A cancelled dictation keeps its recording for `cancelUndoSeconds`, and Undo finishes it; a press while
/// the last dictation is still processing no longer cancels it.
@MainActor
final class CancelUndoTests: XCTestCase {
  nonisolated static let app = "com.example.chat"

  func testAPressWhileTranscribingIsIgnored() async {
    var state = makeState()
    state.isTranscribing = true
    let store = TestStore(initialState: state) { TranscriptionFeature() }

    // Exhaustive: no cancel, no new recording.
    await store.send(.hotKeyPressed)
  }

  func testAPressWhileRewritingIsIgnored() async {
    var state = makeState()
    state.isRewriting = true
    let store = TestStore(initialState: state) { TranscriptionFeature() }

    await store.send(.hotKeyPressed)
  }

  func testEscWhileTranscribingKeepsTheRecordingUntilTheOfferEnds() async throws {
    let audioURL = try makeRecording()
    let clock = TestClock()
    var state = makeState()
    state.isTranscribing = true
    state.sourceAppBundleID = Self.app
    state.sourceAppName = "Chat"
    state.inFlight.holdAudio(audioURL, duration: 4)
    let store = TestStore(initialState: state) {
      TranscriptionFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.sleepManagement.allowSleep = {}
      $0.localLLM.unload = {}
      $0.soundEffects.play = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.cancel)
    await store.receive(\.cancelKept)
    XCTAssertEqual(store.state.cancelled?.audioURL, audioURL)
    XCTAssertEqual(store.state.cancelled?.duration, 4)
    XCTAssertEqual(store.state.cancelled?.sourceAppName, "Chat")
    XCTAssertNil(state.inFlight.takeAudio(), "the transcription no longer owns the recording")

    await clock.advance(by: .seconds(29))
    XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

    await clock.advance(by: .seconds(1))
    await store.receive(\.cancelUndoExpired)
    await store.finish()
    XCTAssertNil(store.state.cancelled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
  }

  func testEscWhileRecordingKeepsTheRecording() async throws {
    let audioURL = try makeRecording()
    let start = Date(timeIntervalSince1970: 1_000)
    var state = makeState()
    state.isRecording = true
    state.recordingStartTime = start
    state.sourceAppBundleID = Self.app
    let store = TestStore(initialState: state) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = start.addingTimeInterval(6)
      $0.continuousClock = TestClock()
      $0.recording.stopRecording = { .captured(audioURL) }
      $0.sleepManagement.allowSleep = {}
      $0.localLLM.unload = {}
      $0.soundEffects.play = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.cancel)
    await store.receive(\.cancelKept)
    XCTAssertEqual(store.state.cancelled?.audioURL, audioURL)
    XCTAssertEqual(store.state.cancelled?.duration, 6)
    XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
    try? FileManager.default.removeItem(at: audioURL)
  }

  func testAQuickCancelIsNotKept() async throws {
    let audioURL = try makeRecording()
    let start = Date(timeIntervalSince1970: 1_000)
    var state = makeState()
    state.isRecording = true
    state.recordingStartTime = start
    let store = TestStore(initialState: state) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = start.addingTimeInterval(0.5)
      $0.recording.stopRecording = { .captured(audioURL) }
      $0.sleepManagement.allowSleep = {}
      $0.localLLM.unload = {}
      $0.soundEffects.play = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.cancel)
    await store.finish()
    XCTAssertNil(store.state.cancelled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
  }

  func testUndoOffIsTheOldDelete() async throws {
    let audioURL = try makeRecording()
    var state = makeState()
    state.$hexSettings.withLock { $0.cancelUndoSeconds = 0 }
    state.isTranscribing = true
    state.inFlight.holdAudio(audioURL, duration: 4)
    let store = TestStore(initialState: state) {
      TranscriptionFeature()
    } withDependencies: {
      $0.sleepManagement.allowSleep = {}
      $0.localLLM.unload = {}
      $0.soundEffects.play = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.cancel)
    await store.finish()
    XCTAssertNil(store.state.cancelled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
  }

  func testUndoPastesIntoTheSameApp() async throws {
    let run = try await runUndo(frontmost: Self.app)
    XCTAssertEqual(run.pasted, "Hello there.")
    XCTAssertNil(run.copied)
    XCTAssertEqual(run.history.first?.text, "Hello there.")
    XCTAssertNil(run.notice)
  }

  func testUndoInAnotherAppGoesToHistory() async throws {
    let run = try await runUndo(frontmost: "com.example.other")
    XCTAssertNil(run.pasted)
    XCTAssertNil(run.copied)
    XCTAssertEqual(run.history.first?.text, "Hello there.")
    XCTAssertEqual(run.notice, .undoSaved("Chat"))
  }

  func testUndoInAnotherAppWithHistoryOffIsCopied() async throws {
    let run = try await runUndo(frontmost: "com.example.other", saveHistory: false)
    XCTAssertNil(run.pasted)
    XCTAssertEqual(run.copied, "Hello there.")
    XCTAssertEqual(run.notice, .undoCopied("Chat"))
  }

  func testUndoWaitsWhileADictationIsRecording() async throws {
    let audioURL = try makeRecording()
    defer { try? FileManager.default.removeItem(at: audioURL) }
    var state = makeState()
    state.cancelled = CancelledDictation(audioURL: audioURL, duration: 3, sourceAppBundleID: Self.app, biasing: .empty)
    state.isRecording = true
    let store = TestStore(initialState: state) { TranscriptionFeature() }

    await store.send(.undoCancel)
  }

  // MARK: - Helpers

  struct Run {
    var pasted: String?
    var copied: String?
    var history: [Transcript]
    var notice: DictationNotice?
  }

  private func runUndo(frontmost: String, saveHistory: Bool = true) async throws -> Run {
    let audioURL = try makeRecording()
    defer { try? FileManager.default.removeItem(at: audioURL) }
    let probe = UndoClipboardProbe()
    let history = Shared(value: TranscriptionHistory())
    var state = makeState(history: history)
    state.$hexSettings.withLock {
      $0.rewriteMode = .raw
      $0.saveTranscriptionHistory = saveHistory
      $0.matchSurroundingText = false
    }
    state.cancelled = CancelledDictation(
      audioURL: audioURL, duration: 3, sourceAppBundleID: Self.app, sourceAppName: "Chat", biasing: .empty
    )
    let store = TestStore(initialState: state) {
      TranscriptionFeature()
    } withDependencies: {
      $0.transcription.transcribe = { _, _, _, _ in "Hello there." }
      $0.sleepManagement.allowSleep = {}
      $0.focusedText.read = { nil }
      $0.focusedText.frontmostBundleID = { frontmost }
      $0.transcriptPersistence.save = { text, url, duration, _, appName in
        Transcript(timestamp: Date(), text: text, audioPath: url, duration: duration, sourceAppName: appName)
      }
      $0.pasteboard.paste = { text in await probe.paste(text) }
      $0.pasteboard.copy = { text in await probe.copy(text) }
      $0.pasteboard.sendKeyboardCommand = { _ in }
      $0.soundEffects.play = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.undoCancel)
    await store.finish()
    await store.skipReceivedActions(strict: false)
    XCTAssertNil(store.state.cancelled)
    XCTAssertFalse(store.state.isTranscribing)
    return Run(
      pasted: await probe.pasted,
      copied: await probe.copied,
      history: history.wrappedValue.history,
      notice: store.state.notice?.notice
    )
  }

  private func makeState(history: Shared<TranscriptionHistory> = Shared(value: TranscriptionHistory())) -> TranscriptionFeature.State {
    TranscriptionFeature.State(
      hexSettings: Shared(value: .init()),
      isRemappingScratchpadFocused: false,
      modelBootstrapState: Shared(value: .init(isModelReady: true)),
      transcriptionHistory: history
    )
  }

  private func makeRecording() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("undo-\(UUID().uuidString).wav")
    try Data("audio".utf8).write(to: url)
    return url
  }
}

private actor UndoClipboardProbe {
  private(set) var pasted: String?
  private(set) var copied: String?

  func paste(_ text: String) { pasted = text }
  func copy(_ text: String) { copied = text }
}
