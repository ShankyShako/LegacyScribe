import ComposableArchitecture
import Foundation
import HexCore
import XCTest

@testable import Hex

@MainActor
final class HistoryPlaybackTests: XCTestCase {
  func testStoppingPlaybackCompletesWaitersExactlyOnce() async {
    let controller = AudioPlayerController()
    let waiter = Task {
      await controller.waitForPlaybackToFinish()
    }

    await Task.yield()
    controller.stop()
    controller.stop()

    await waiter.value
    await controller.waitForPlaybackToFinish()
  }

  func testStalePlaybackFinishedDoesNotStopCurrentPlayback() async {
    let transcriptID = UUID()
    let playbackID = UUID()
    let store = TestStore(
      initialState: HistoryFeature.State(
        transcriptionHistory: Shared(value: .init()),
        playingTranscriptID: transcriptID,
        playbackID: playbackID
      )
    ) {
      HistoryFeature()
    }

    await store.send(.playbackFinished(UUID()))

    XCTAssertEqual(store.state.playingTranscriptID, transcriptID)
    XCTAssertEqual(store.state.playbackID, playbackID)
  }

  func testFirstPlayWaitsForWordTimingsBeforeTheAudioStarts() async {
    let id = UUID()
    let words = [SpokenWord(word: "hello", start: 0.1, end: 0.4)]
    let requested = LockIsolated(0)
    let transcript = Transcript(id: id, timestamp: Date(), text: "hello", audioPath: URL(fileURLWithPath: "/tmp/missing.flac"), duration: 1)
    let store = TestStore(
      initialState: HistoryFeature.State(transcriptionHistory: Shared(value: .init(history: [transcript])))
    ) {
      HistoryFeature()
    } withDependencies: {
      $0.transcription.timedWords = { _, _, _ in
        requested.withValue { $0 += 1 }
        return words
      }
    }
    store.exhaustivity = .off

    await store.send(.playTranscript(id))
    XCTAssertNil(store.state.audioPlayerController, "audio started before the timings")
    await store.receive(\.playbackReady)
    XCTAssertEqual(requested.value, 1)
  }
}
