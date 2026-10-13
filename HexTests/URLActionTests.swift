import ComposableArchitecture
import Foundation
import HexCore
import XCTest

@testable import Hex

/// `legacyscribe://` actions: those that turn the microphone on wait for the setting, the rest always work.
@MainActor
final class URLActionTests: XCTestCase {
  func testStartIsIgnoredWhileURLActionsAreOff() async {
    let store = makeStore(urlActionsEnabled: false)

    await store.send(.urlAction(.start))
    await store.send(.urlAction(.toggle))
    await store.send(.urlAction(.notesStart))

    XCTAssertFalse(store.state.isRecording)
    XCTAssertNil(store.state.notesRecording)
  }

  func testModeChangesWorkWithURLActionsOff() async {
    let store = makeStore(urlActionsEnabled: false)

    await store.send(.urlAction(.mode(.prompt)))

    XCTAssertEqual(store.state.hexSettings.rewriteMode, .prompt)
  }

  func testStopAndCancelDoNothingWhenIdle() async {
    let store = makeStore(urlActionsEnabled: false)

    await store.send(.urlAction(.stop))
    await store.send(.urlAction(.notesStop))
    await store.send(.urlAction(.cancel))

    XCTAssertFalse(store.state.isRecording)
    XCTAssertFalse(store.state.isTranscribing)
  }

  private func makeStore(urlActionsEnabled: Bool) -> TestStoreOf<TranscriptionFeature> {
    let store = TestStore(
      initialState: TranscriptionFeature.State(
        hexSettings: Shared(value: .init(rewriteMode: .clean, urlActionsEnabled: urlActionsEnabled)),
        isRemappingScratchpadFocused: false,
        modelBootstrapState: Shared(value: .init(isModelReady: true)),
        transcriptionHistory: Shared(value: .init())
      )
    ) {
      TranscriptionFeature()
    }
    store.exhaustivity = .off
    return store
  }
}
