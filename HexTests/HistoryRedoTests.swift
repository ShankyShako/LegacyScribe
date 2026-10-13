import ComposableArchitecture
import Foundation
import HexCore
import WhisperKit
import XCTest

@testable import Hex

/// History's context menu: rewrite an entry again in another mode, or transcribe its recording with another
/// engine and replace the text only on request.
@MainActor
final class HistoryRedoTests: XCTestCase {
  struct Offline: Error, LocalizedError { var errorDescription: String? { "offline" } }

  static let entryID = UUID()
  static let primary = RewriteEndpoint(provider: .custom, baseURL: "http://localhost:20128/v1", model: "groq/openai/gpt-oss-120b")

  func testRewriteAgainStartsFromTheHeardWordsAndKeepsThem() async {
    let sent = LockIsolated<String?>(nil)
    let (store, history) = makeStore { $0.rewrite.complete = { _, _, messages in
      sent.setValue(messages.last?.content)
      return "Here is the plan:\n- Ship it."
    } }

    await store.send(.rewriteAgain(Self.entryID, .prompt))
    await store.receive(\.redoFinished)

    let entry = history.wrappedValue.history.first
    XCTAssertEqual(entry?.text, "Here is the plan:\n- Ship it.")
    XCTAssertEqual(entry?.rawText, "um so ship it")
    XCTAssertEqual(entry?.rewriteMode, .prompt)
    XCTAssertEqual(entry?.rewrittenBy, Self.primary.model)
    XCTAssertTrue(sent.value?.contains("um so ship it") == true)
    XCTAssertTrue(store.state.working.isEmpty)
  }

  func testAFailedRewriteAgainLeavesTheEntryAndSaysWhy() async {
    let (store, history) = makeStore { $0.rewrite.complete = { _, _, _ in throw Offline() } }

    await store.send(.rewriteAgain(Self.entryID, .clean))
    await store.receive(\.redoFinished)

    XCTAssertEqual(history.wrappedValue.history.first?.text, "So ship it.")
    XCTAssertEqual(history.wrappedValue.history.first?.rewriteMode, .clean)
    XCTAssertEqual(store.state.redoErrors[Self.entryID], "Rewrite failed: primary \(Self.primary.model): offline")
  }

  func testTranscribeAgainShowsTheResultAndReplacesOnlyOnRequest() async {
    let usedEngine = LockIsolated<String?>(nil)
    let (store, history) = makeStore { $0.transcription.transcribe = { _, engine, _, _ in
      usedEngine.setValue(engine)
      return "So, ship it."
    } }
    await store.send(.enginesLoaded([HistoryEngine(name: "parakeet-tdt-0.6b-v3-coreml", displayName: "Parakeet TDT v3")]))

    await store.send(.transcribeAgain(Self.entryID, engine: "parakeet-tdt-0.6b-v3-coreml"))
    await store.receive(\.redoFinished)

    XCTAssertEqual(usedEngine.value, "parakeet-tdt-0.6b-v3-coreml")
    XCTAssertEqual(store.state.alternates[Self.entryID], AlternateTranscript(engine: "Parakeet TDT v3", text: "So, ship it."))
    XCTAssertEqual(history.wrappedValue.history.first?.text, "So ship it.")

    await store.send(.replaceWithAlternate(Self.entryID))
    let entry = history.wrappedValue.history.first
    XCTAssertEqual(entry?.text, "So, ship it.")
    XCTAssertNil(entry?.rawText)
    XCTAssertNil(entry?.rewriteMode)
    XCTAssertNil(store.state.alternates[Self.entryID])
  }

  func testTranscribeAgainNeedsTheRecording() async {
    let (store, _) = makeStore(audioRemoved: true) { $0.transcription.transcribe = { _, _, _, _ in
      XCTFail("transcribed without a recording")
      return ""
    } }

    await store.send(.transcribeAgain(Self.entryID, engine: "parakeet-tdt-0.6b-v3-coreml"))

    XCTAssertTrue(store.state.working.isEmpty)
    XCTAssertNil(store.state.alternates[Self.entryID])
  }

  private func makeStore(
    audioRemoved: Bool = false,
    dependencies: @escaping (inout DependencyValues) -> Void
  ) -> (TestStoreOf<HistoryFeature>, Shared<TranscriptionHistory>) {
    @Shared(.hexSettings) var settings: HexSettings
    $settings.withLock {
      $0.rewritePrimary = Self.primary
      $0.rewriteFallbackEnabled = false
      $0.privateMode = false
    }
    let entry = Transcript(
      id: Self.entryID,
      timestamp: Date(),
      text: "So ship it.",
      audioPath: URL(fileURLWithPath: "/tmp/entry.wav"),
      duration: 2,
      rawText: "um so ship it",
      rewriteMode: .clean,
      rewrittenBy: "earlier-model",
      audioRemoved: audioRemoved ? true : nil
    )
    let history = Shared(value: TranscriptionHistory(history: [entry]))
    let store = TestStore(initialState: HistoryFeature.State(transcriptionHistory: history)) {
      HistoryFeature()
    } withDependencies: {
      $0.keychain.read = { _ in nil }
      dependencies(&$0)
    }
    store.exhaustivity = .off
    return (store, history)
  }
}
