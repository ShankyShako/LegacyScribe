import ComposableArchitecture
import Foundation
import HexCore
import XCTest

@testable import Hex

/// Notes mode (P3.6 D1): a quick tap starts a session, a hold is an ordinary dictation in the mode picked
/// before Notes, and a session ended in its first seconds is deleted rather than listed.
@MainActor
final class NotesModeTests: XCTestCase {
  func testATapReplacesTheDictationItsPressStarted() async throws {
    let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("notes-tap-\(UUID().uuidString).wav")
    try Data("audio".utf8).write(to: audioURL)
    let sounds = LockIsolated<[SoundEffect]>([])
    var state = makeState()
    state.isRecording = true
    state.recordingStartTime = Date(timeIntervalSince1970: 1_000)
    let store = TestStore(initialState: state) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_000.2)
      $0.continuousClock = TestClock()
      $0.recording.stopRecording = { .captured(audioURL) }
      $0.notes.start = { "2026-10-15-140000" }
      $0.sleepManagement.preventSleep = { _ in }
      $0.sleepManagement.allowSleep = {}
      $0.soundEffects.play = { sound in sounds.withValue { $0.append(sound) } }
    }
    store.exhaustivity = .off

    await store.send(.notesTapped)
    XCTAssertFalse(store.state.isRecording)
    XCTAssertNotNil(store.state.notesRecording)
    await store.receive(\.notesStarted)
    XCTAssertEqual(store.state.notesRecording?.id, "2026-10-15-140000")
    await store.skipInFlightEffects()
    XCTAssertEqual(sounds.value, [.startRecording], "one sound: the session's")
    XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path), "the dropped dictation's audio is deleted")
  }

  func testAHoldPastTheTapWindowIsADictation() async {
    let clock = TestClock()
    let sounds = LockIsolated<[SoundEffect]>([])
    let store = TestStore(initialState: makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_000)
      $0.continuousClock = clock
      $0.recording.startRecording = {}
      $0.transcription.prewarm = { _ in }
      $0.sleepManagement.preventSleep = { _ in }
      $0.soundEffects.play = { sound in sounds.withValue { $0.append(sound) } }
    }
    store.exhaustivity = .off

    await store.send(.startRecording)
    XCTAssertTrue(sounds.value.isEmpty, "no sound until the press outlasts a tap")
    await clock.advance(by: .seconds(NotesTapDetector.tapWindow))
    await store.receive(\.notesHoldConfirmed)
    XCTAssertTrue(store.state.notesHold)
    XCTAssertEqual(sounds.value, [.startRecording])
    XCTAssertEqual(store.state.hexSettings.dictationMode, .prompt)
  }

  func testStoppingInTheFirstSecondsDiscardsTheSession() async {
    let calls = LockIsolated<[String]>([])
    let store = makeSessionStore(secondsIn: 4, calls: calls)

    await store.send(.notesTapped)
    await store.finish()
    XCTAssertNil(store.state.notesRecording)
    XCTAssertEqual(calls.value, ["discard"])
  }

  func testStoppingLaterKeepsTheSession() async {
    let calls = LockIsolated<[String]>([])
    let store = makeSessionStore(secondsIn: 6, calls: calls)

    await store.send(.notesTapped)
    await store.finish()
    XCTAssertEqual(calls.value, ["stop"])
  }

  func testEscDiscardsUntilTenSeconds() async {
    let early = LockIsolated<[String]>([])
    let earlyStore = makeSessionStore(secondsIn: 8, calls: early)
    await earlyStore.send(.cancel)
    await earlyStore.finish()
    XCTAssertEqual(early.value, ["discard"])

    let late = LockIsolated<[String]>([])
    let lateStore = makeSessionStore(secondsIn: 11, calls: late)
    await lateStore.send(.cancel)
    await lateStore.finish()
    XCTAssertEqual(late.value, ["stop"])
  }

  // MARK: - Helpers

  /// Notes mode, picked after Prompt; no field reads or Legacy peek.
  private func makeState() -> TranscriptionFeature.State {
    var settings = HexSettings(rewriteMode: .prompt)
    settings.rewriteMode = .notes
    settings.contextTermsEnabled = false
    settings.superEnabled = false
    return TranscriptionFeature.State(
      hexSettings: Shared(value: settings),
      isRemappingScratchpadFocused: false,
      modelBootstrapState: Shared(value: .init(isModelReady: true)),
      transcriptionHistory: Shared(value: TranscriptionHistory())
    )
  }

  /// A session that has been recording for `secondsIn`.
  private func makeSessionStore(secondsIn: TimeInterval, calls: LockIsolated<[String]>) -> TestStoreOf<TranscriptionFeature> {
    let start = Date(timeIntervalSince1970: 1_000)
    var state = makeState()
    state.notesRecording = NotesRecording(id: "2026-10-15-140000", startedAt: start)
    let store = TestStore(initialState: state) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = start.addingTimeInterval(secondsIn)
      $0.notes.stop = { calls.withValue { $0.append("stop") } }
      $0.notes.discard = { calls.withValue { $0.append("discard") } }
      $0.sleepManagement.allowSleep = {}
      $0.soundEffects.play = { _ in }
    }
    store.exhaustivity = .off
    return store
  }
}
