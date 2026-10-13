import ComposableArchitecture
import Foundation
import HexCore
import XCTest

@testable import Hex

@MainActor
final class SuperPipelineTests: XCTestCase {
  struct Offline: Error, LocalizedError { var errorDescription: String? { "offline" } }

  static let primary = RewriteEndpoint(provider: .custom, baseURL: "http://localhost:20128/v1", model: "groq/openai/gpt-oss-120b")
  static let fallback = RewriteEndpoint(provider: .ollama, baseURL: "http://localhost:11434/v1", model: "qwen3:8b")
  nonisolated static let app = "com.example.mail"

  /// "Hello world" selected at the start of the field.
  static let selected = FocusedText(bundleID: app, value: "Hello world, see you soon", cursor: 0, selectionLength: 11)

  func testAnEditGoesOverTheSelection() async {
    let run = await runDictation("Legacy, make it French.", field: Self.selected) { _, _, messages in
      XCTAssertEqual(messages.last?.content, "<selection>\nHello world\n</selection>\n<instruction>\nmake it French.\n</instruction>")
      return "Bonjour le monde"
    }
    XCTAssertEqual(run.pasted, "Bonjour le monde")
    XCTAssertNil(run.copied)
    XCTAssertEqual(run.history.first?.text, "Bonjour le monde")
    XCTAssertEqual(run.history.first?.rawText, "Legacy, make it French.")
    XCTAssertNil(run.notice)
    XCTAssertFalse(run.superActive)
  }

  func testAFailedEditLeavesTheSelectionAndCopiesTheDictation() async {
    let run = await runDictation("Legacy, make it French.", field: Self.selected) { _, _, _ in throw Offline() }
    XCTAssertNil(run.pasted)
    XCTAssertEqual(run.copied, "Legacy, make it French.")
    XCTAssertEqual(run.history.first?.text, "Legacy, make it French.")
    XCTAssertEqual(run.history.first?.rewriteFailures?.count, 2)
    XCTAssertEqual(run.notice, .superFailed("Legacy failed: nothing changed"))
    XCTAssertFalse(run.superActive)
  }

  func testNothingIsPastedWhenTheSelectionChangedMeanwhile() async {
    let moved = FocusedText(bundleID: Self.app, value: "Hello world, see you soon", cursor: 25)
    let run = await runDictation("Legacy, make it French.", field: Self.selected, fieldLater: moved) { _, _, _ in
      "Bonjour le monde"
    }
    XCTAssertNil(run.pasted)
    XCTAssertEqual(run.copied, "Legacy, make it French.")
    XCTAssertEqual(run.notice, .superFailed("Legacy stopped: the selection changed"))
  }

  func testWithNothingSelectedItWritesAtTheCursorWithTheFieldAsContext() async {
    let field = FocusedText(bundleID: Self.app, value: "Dinner Thursday?\n", cursor: 17)
    let run = await runDictation("Legacy. Reply saying I'm in.", field: field) { _, _, messages in
      XCTAssertEqual(messages.last?.content, "<field>\nDinner Thursday?\n<cursor/>\n</field>\n<instruction>\nReply saying I'm in.\n</instruction>")
      return "I'm in!"
    }
    XCTAssertEqual(run.pasted, "I'm in!")
  }

  func testTerminalsGetNoFieldContext() async {
    let terminal = FocusedText(bundleID: "com.apple.Terminal", value: "$ ls\nfoo bar", cursor: 3, selectionLength: 2)
    let run = await runDictation("Legacy, write a commit message for the typo fix", field: terminal, sourceApp: "com.apple.Terminal") {
      _, _, messages in
      XCTAssertEqual(messages.last?.content, "<instruction>\nwrite a commit message for the typo fix\n</instruction>")
      return "Fix typo"
    }
    XCTAssertEqual(run.pasted, "Fix typo")
  }

  func testSuperAloneDoesNothing() async {
    let run = await runDictation("Legacy!", field: Self.selected) { _, _, _ in
      XCTFail("the LLM was called without an instruction")
      return ""
    }
    XCTAssertNil(run.pasted)
    XCTAssertTrue(run.history.isEmpty)
    XCTAssertEqual(run.notice, .superFailed("Say what to do after \u{201C}legacy\u{201D}"))
  }

  func testLegacyCodeIsAnOrdinaryDictation() async {
    let run = await runDictation("Legacy code is hard to change.", field: Self.selected) { _, _, messages in
      XCTAssertEqual(messages.last?.content, "<dictation>\nLegacy code is hard to change.\n</dictation>")
      return "Legacy code is hard to change!"
    }
    XCTAssertEqual(run.pasted, "Legacy code is hard to change!")
  }

  func testTurnedOffSuperIsAnOrdinaryDictation() async {
    let run = await runDictation("Legacy, make it French.", field: Self.selected, superEnabled: false) { _, _, messages in
      XCTAssertEqual(messages.last?.content, "<dictation>\nLegacy, make it French.\n</dictation>")
      return "Legacy, make it French."
    }
    // Pasted over the selection like any dictation, fitted to the ", see you soon" after it.
    XCTAssertEqual(run.pasted, "Legacy, make it French")
  }

  func testASelectionAtKeyDownShowsTheHintThreeTimes() async {
    let settings = Shared(value: HexSettings())
    var state = TranscriptionFeature.State(hexSettings: settings)
    state.isRecording = true
    let store = TestStore(initialState: state) { TranscriptionFeature() }
    store.exhaustivity = .off
    for _ in 0 ..< 4 {
      await store.send(.fieldContextCaptured(Self.selected))
    }
    XCTAssertEqual(settings.wrappedValue.superHintsShown, SuperTrigger.hintLimit)
    XCTAssertEqual(store.state.notice?.serial, SuperTrigger.hintLimit)
    XCTAssertEqual(store.state.notice?.notice, .superHint)
  }

  func testTheEarlyLookFollowsThePeekAndEndsWithAnOrdinaryTranscript() async {
    var state = TranscriptionFeature.State(
      hexSettings: Shared(value: .init(rewriteMode: .raw)),
      isRemappingScratchpadFocused: false,
      modelBootstrapState: Shared(value: .init(isModelReady: true)),
      transcriptionHistory: Shared(value: TranscriptionHistory())
    )
    state.isRecording = true
    let store = TestStore(initialState: state) {
      TranscriptionFeature()
    } withDependencies: {
      $0.transcriptPersistence.save = { text, audioURL, duration, _, _ in
        Transcript(timestamp: Date(), text: text, audioPath: audioURL, duration: duration)
      }
      $0.pasteboard.paste = { _ in }
      $0.soundEffects.play = { _ in }
    }
    store.exhaustivity = .off
    await store.send(.superHeard(true)) { $0.superActive = true }
    await store.send(.superHeard(false)) { $0.superActive = false }
    await store.send(.superHeard(true)) { $0.superActive = true }
    await store.send(.transcriptionResult(
      "Legacy code is hard to change.", FileManager.default.temporaryDirectory.appendingPathComponent("early-\(UUID().uuidString).wav"),
      1, DictationTimeline(keyUp: .now)
    )) { $0.superActive = false }
    await store.finish()
  }

  struct Run {
    var pasted: String?
    var copied: String?
    var history: [Transcript]
    var notice: DictationNotice?
    var superActive: Bool
  }

  /// Sends one transcription result through the pipeline with `field` read at key-down; `fieldLater` is what
  /// the field reads after that (the same field by default).
  private func runDictation(
    _ transcript: String,
    field: FocusedText,
    fieldLater: FocusedText? = nil,
    sourceApp: String = app,
    superEnabled: Bool = true,
    complete: @escaping @Sendable (RewriteEndpoint, String?, [ChatMessage]) async throws -> String
  ) async -> Run {
    let audioURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("legacy-\(UUID().uuidString).wav")
    let probe = ClipboardProbe()
    let history = Shared(value: TranscriptionHistory())
    var state = TranscriptionFeature.State(
      hexSettings: Shared(value: .init(
        rewriteMode: .clean,
        rewritePrimary: Self.primary,
        rewriteFallback: Self.fallback,
        rewriteFallbackEnabled: true,
        superEnabled: superEnabled
      )),
      isRemappingScratchpadFocused: false,
      modelBootstrapState: Shared(value: .init(isModelReady: true)),
      transcriptionHistory: history
    )
    state.sourceAppBundleID = sourceApp
    state.superField = superEnabled ? field : nil
    let later = fieldLater ?? field
    let store = TestStore(initialState: state) {
      TranscriptionFeature()
    } withDependencies: {
      $0.rewrite.complete = complete
      $0.keychain.read = { _ in nil }
      $0.codeTalk.slashCommands = { [] }
      $0.focusedText.read = { later }
      $0.pasteboard.sendKeyboardCommand = { _ in }
      $0.transcriptPersistence.save = { text, audioURL, duration, bundleID, appName in
        Transcript(timestamp: Date(), text: text, audioPath: audioURL, duration: duration)
      }
      $0.pasteboard.paste = { text in await probe.paste(text) }
      $0.pasteboard.copy = { text in await probe.copy(text) }
      $0.soundEffects.play = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.transcriptionResult(transcript, audioURL, 1, DictationTimeline(keyUp: .now)))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    return Run(
      pasted: await probe.pasted,
      copied: await probe.copied,
      history: history.wrappedValue.history,
      notice: store.state.notice?.notice,
      superActive: store.state.superActive
    )
  }
}

private actor ClipboardProbe {
  private(set) var pasted: String?
  private(set) var copied: String?

  func paste(_ text: String) { pasted = text }
  func copy(_ text: String) { copied = text }
}
