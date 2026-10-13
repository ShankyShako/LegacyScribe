import ComposableArchitecture
import Foundation
import HexCore
import XCTest

@testable import Hex

@MainActor
final class RewritePipelineTests: XCTestCase {
  struct Offline: Error, LocalizedError { var errorDescription: String? { "offline" } }

  /// Fresh installs rewrite on-device with the backup off; these tests need two servers that need no key.
  static let primary = RewriteEndpoint(provider: .custom, baseURL: "http://localhost:20128/v1", model: "groq/openai/gpt-oss-120b")
  static let fallback = RewriteEndpoint(provider: .ollama, baseURL: "http://localhost:11434/v1", model: "qwen3:8b")

  func testFallbackRewriteIsPastedAndOriginalKept() async {
    let pasted = await runDictation("um so hi there") { endpoint, _, _ in
      if endpoint.model == Self.primary.model { throw Offline() }
      return "So, hi there."
    }
    XCTAssertEqual(pasted.text, "So, hi there.")
    let entry = pasted.history.first
    XCTAssertEqual(entry?.text, "So, hi there.")
    XCTAssertEqual(entry?.rawText, "um so hi there")
    XCTAssertEqual(entry?.rewriteMode, .clean)
    XCTAssertEqual(entry?.rewrittenBy, Self.fallback.model)
    XCTAssertEqual(entry?.rewriteFailures, ["primary \(Self.primary.model): offline"])
  }

  func testTranscriptIsPastedWhenEveryEndpointFails() async {
    let pasted = await runDictation("um so hi there") { _, _, _ in throw Offline() }
    XCTAssertEqual(pasted.text, "um so hi there")
    let entry = pasted.history.first
    XCTAssertEqual(entry?.text, "um so hi there")
    XCTAssertNil(entry?.rawText)
    XCTAssertNil(entry?.rewriteMode)
    XCTAssertEqual(entry?.rewriteFailures?.count, 2)
  }

  func testRawModeNeverCallsTheLLM() async {
    let pasted = await runDictation("um so hi there", mode: .raw) { _, _, _ in
      XCTFail("rewrite called in raw mode")
      return ""
    }
    XCTAssertEqual(pasted.text, "um so hi there")
    XCTAssertNil(pasted.history.first?.rewriteFailures)
  }

  func testPasteMatchesTheTextAroundTheCursorButHistoryDoesNot() async {
    let pasted = await runDictation("The report is ready.", mode: .raw, field: "I think and we ship", cursor: 8) { _, _, _ in
      XCTFail("rewrite called in raw mode")
      return ""
    }
    XCTAssertEqual(pasted.text, "the report is ready ")
    XCTAssertEqual(pasted.history.first?.text, "The report is ready.")
  }

  func testLeadingSlashCommandIsPastedAsIsMidSentence() async {
    let pasted = await runDictation("Slash pick up.", mode: .prompt, slashCommands: ["pickup"], field: "see", cursor: 3) { _, _, _ in
      XCTFail("rewrite called for a bare command")
      return ""
    }
    XCTAssertEqual(pasted.text, "/pickup")
  }

  func testLeadingSlashCommandSkipsTheLLMWhenNothingFollows() async {
    let pasted = await runDictation("Slash pick up.", mode: .prompt, slashCommands: ["pickup"]) { _, _, _ in
      XCTFail("rewrite called for a bare command")
      return ""
    }
    XCTAssertEqual(pasted.text, "/pickup")
    XCTAssertEqual(pasted.history.first?.rawText, "Slash pick up.")
  }

  func testLeadingSlashCommandPrefixesTheRewrittenRest() async {
    let pasted = await runDictation("Slash handoff, um, and note the open bug", mode: .prompt, slashCommands: ["handoff"]) {
      _, _, messages in
      XCTAssertEqual(messages.last?.content, "<dictation>\nand note the open bug\n</dictation>")
      XCTAssertTrue(messages.first?.content.contains("/handoff") == true)
      return "Note the open bug."
    }
    XCTAssertEqual(pasted.text, "/handoff Note the open bug.")
  }

  func testLeadingSlashCommandSurvivesAFailedRewrite() async {
    let pasted = await runDictation("Slash handoff and note the open bug", mode: .prompt, slashCommands: ["handoff"]) {
      _, _, _ in throw Offline()
    }
    XCTAssertEqual(pasted.text, "/handoff and note the open bug")
  }

  func testCodeTalkIsPromptModeOnly() async {
    let pasted = await runDictation("Slash handoff", mode: .clean, slashCommands: ["handoff"]) { _, _, messages in
      XCTAssertFalse(messages.first?.content.contains("Code talk") == true)
      return "Slash handoff."
    }
    XCTAssertEqual(pasted.text, "Slash handoff.")
  }

  func testPrivateModeNeverCallsANetworkEndpoint() async {
    let pasted = await runDictation("um so hi there", privateMode: true) { _, _, _ in
      XCTFail("a network endpoint was called in Private mode")
      return ""
    }
    XCTAssertEqual(pasted.text, "um so hi there")
    XCTAssertNil(pasted.history.first?.rewriteFailures, "a skipped endpoint isn't a failure")
  }

  private let dessertList = "## Desserts\n- Tiramisu\n- Lemon tart"

  func testPromptMergesIntoTheFieldAndReplacesIt() async {
    let pasted = await runDictation("add cheesecake", mode: .prompt, field: dessertList) { _, _, messages in
      XCTAssertTrue(messages.last?.content.hasPrefix("<existing>\n## Desserts") == true)
      return "## Desserts\n- Tiramisu\n- Lemon tart\n- Cheesecake"
    }
    XCTAssertEqual(pasted.text, "## Desserts\n- Tiramisu\n- Lemon tart\n- Cheesecake")
    XCTAssertEqual(pasted.commands, [KeyboardCommand(key: .a, modifiers: [.command])])
  }

  func testAMergeThatDropsTheFieldTextPastesTheTranscriptAtTheCursor() async {
    let pasted = await runDictation("add cheesecake", mode: .prompt, field: dessertList) { _, _, _ in
      "- Cheesecake"
    }
    XCTAssertEqual(pasted.text, "add cheesecake")
    XCTAssertEqual(pasted.commands, [])
  }

  func testCleanModeNeverMerges() async {
    let pasted = await runDictation("um add cheesecake", mode: .clean, field: dessertList) { _, _, messages in
      XCTAssertEqual(messages.last?.content, "<dictation>\num add cheesecake\n</dictation>")
      return "Add cheesecake."
    }
    XCTAssertEqual(pasted.text, "Add cheesecake.")
    XCTAssertEqual(pasted.commands, [])
  }

  /// Sends one transcription result through the pipeline and returns what was pasted and stored.
  private func runDictation(
    _ transcript: String,
    mode: RewriteMode = .clean,
    slashCommands: [String] = [],
    field: String? = nil,
    cursor: Int? = nil,
    privateMode: Bool = false,
    complete: @escaping @Sendable (RewriteEndpoint, String?, [ChatMessage]) async throws -> String
  ) async -> (text: String, history: [Transcript], commands: [KeyboardCommand]) {
    let audioURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("rewrite-\(UUID().uuidString).wav")
    let paste = PasteProbe()
    let history = Shared(value: TranscriptionHistory())
    var state = TranscriptionFeature.State(
      hexSettings: Shared(value: .init(
        rewriteMode: mode,
        rewritePrimary: Self.primary,
        rewriteFallback: Self.fallback,
        rewriteFallbackEnabled: true,
        privateMode: privateMode
      )),
      isRemappingScratchpadFocused: false,
      modelBootstrapState: Shared(value: .init(isModelReady: true)),
      transcriptionHistory: history
    )
    state.sourceAppBundleID = "com.example.chat"
    let store = TestStore(initialState: state) {
      TranscriptionFeature()
    } withDependencies: {
      $0.rewrite.complete = complete
      $0.keychain.read = { _ in nil }
      $0.codeTalk.slashCommands = { slashCommands }
      $0.focusedText.read = { field.map { FocusedText(bundleID: "com.example.chat", value: $0, cursor: cursor) } }
      $0.pasteboard.sendKeyboardCommand = { command in await paste.record(command) }
      $0.transcriptPersistence.save = { text, audioURL, duration, bundleID, appName in
        Transcript(timestamp: Date(), text: text, audioPath: audioURL, duration: duration)
      }
      $0.pasteboard.paste = { text in await paste.record(text) }
      $0.soundEffects.play = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.transcriptionResult(transcript, audioURL, 1, DictationTimeline(keyUp: .now)))
    await store.finish()
    return (await paste.text ?? "", history.wrappedValue.history, await paste.commands)
  }
}

private actor PasteProbe {
  private(set) var text: String?
  private(set) var commands: [KeyboardCommand] = []

  func record(_ text: String) {
    self.text = text
  }

  func record(_ command: KeyboardCommand) {
    commands.append(command)
  }
}
