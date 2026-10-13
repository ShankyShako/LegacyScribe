import ComposableArchitecture
import Foundation
import HexCore
import WhisperKit
import XCTest

@testable import Hex

/// A dictation the engine couldn't transcribe is kept in History with its recording, and Retry fills it in.
@MainActor
final class FailedDictationTests: XCTestCase {
  struct EngineFailed: Error, LocalizedError { var errorDescription: String? { "The model isn't loaded" } }

  func testAFailedTranscriptionKeepsTheRecordingInHistory() async {
    let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("failed-\(UUID().uuidString).wav")
    let saved = LockIsolated<URL?>(nil)
    let history = Shared(value: TranscriptionHistory())
    var state = TranscriptionFeature.State(
      hexSettings: Shared(value: .init()),
      isRemappingScratchpadFocused: false,
      modelBootstrapState: Shared(value: .init(isModelReady: true)),
      transcriptionHistory: history
    )
    state.isTranscribing = true
    state.sourceAppName = "Chat"
    let store = TestStore(initialState: state) {
      TranscriptionFeature()
    } withDependencies: {
      $0.transcriptPersistence.save = { text, url, duration, bundleID, appName in
        saved.setValue(url)
        return Transcript(timestamp: Date(), text: text, audioPath: url, duration: duration, sourceAppName: appName)
      }
    }
    store.exhaustivity = .off

    await store.send(.transcriptionFailed(EngineFailed(), audioURL, 3))
    await store.receive(\.failedDictationKept)

    XCTAssertEqual(saved.value, audioURL)
    XCTAssertFalse(store.state.isTranscribing)
    XCTAssertEqual(store.state.notice?.notice, .dictationKept)
    let entry = history.wrappedValue.history.first
    XCTAssertEqual(entry?.text, "")
    XCTAssertEqual(entry?.failure, "The model isn't loaded")
    XCTAssertEqual(entry?.duration, 3)
    XCTAssertEqual(entry?.sourceAppName, "Chat")
  }

  func testRetryFillsTheEntryAndCopiesIt() async {
    let (store, history, copied) = makeHistoryStore { _, _, _, _ in "Hello there." }

    await store.send(.retryTranscript(Self.failedID))
    await store.receive(\.retryFinished)

    let entry = history.wrappedValue.history.first
    XCTAssertEqual(entry?.text, "Hello there.")
    XCTAssertNil(entry?.failure)
    XCTAssertEqual(copied.value, "Hello there.")
    XCTAssertTrue(store.state.working.isEmpty)
  }

  func testARetryThatFailsAgainKeepsTheEntryWithTheNewReason() async {
    let (store, history, copied) = makeHistoryStore { _, _, _, _ in throw EngineFailed() }

    await store.send(.retryTranscript(Self.failedID))
    await store.receive(\.retryFinished)

    let entry = history.wrappedValue.history.first
    XCTAssertEqual(entry?.text, "")
    XCTAssertEqual(entry?.failure, "The model isn't loaded")
    XCTAssertNil(copied.value)
    XCTAssertTrue(store.state.working.isEmpty)
  }

  func testRetryNeedsTheRecording() async {
    let (store, history, _) = makeHistoryStore(audioRemoved: true) { _, _, _, _ in
      XCTFail("transcribed without a recording")
      return ""
    }

    await store.send(.retryTranscript(Self.failedID))

    XCTAssertEqual(history.wrappedValue.history.first?.failure, "Engine error")
    XCTAssertTrue(store.state.working.isEmpty)
  }

  static let failedID = UUID()

  private func makeHistoryStore(
    audioRemoved: Bool = false,
    transcribe: @escaping @Sendable (URL, String, DecodingOptions, @escaping (Progress) -> Void) async throws -> String
  ) -> (TestStoreOf<HistoryFeature>, Shared<TranscriptionHistory>, LockIsolated<String?>) {
    @Shared(.hexSettings) var settings: HexSettings
    $settings.withLock { $0.rewriteMode = .raw }
    let failed = Transcript(
      id: Self.failedID,
      timestamp: Date(),
      text: "",
      audioPath: URL(fileURLWithPath: "/tmp/failed.wav"),
      duration: 2,
      audioRemoved: audioRemoved ? true : nil,
      failure: "Engine error"
    )
    let history = Shared(value: TranscriptionHistory(history: [failed]))
    let copied = LockIsolated<String?>(nil)
    let store = TestStore(initialState: HistoryFeature.State(transcriptionHistory: history)) {
      HistoryFeature()
    } withDependencies: {
      $0.transcription.transcribe = transcribe
      $0.pasteboard.copy = { text in copied.setValue(text) }
    }
    store.exhaustivity = .off
    return (store, history, copied)
  }
}
