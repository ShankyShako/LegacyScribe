import AppKit
import HexCore
import SwiftUI
import XCTest

@testable import Hex

/// Renders a history row mid-playback to a PNG (`$TMPDIR/karaoke-*.png`) for a look; it checks only that
/// the highlighted row renders and differs from the idle one.
@MainActor
final class HistoryKaraokeSnapshotTests: XCTestCase {
  func testPlayingRowHighlightsTheSpokenWord() throws {
    let transcript = Transcript(
      timestamp: Date(), text: "So the menu bar app crashed again.",
      audioPath: URL(fileURLWithPath: "/tmp/a.wav"), duration: 3
    )
    let words = ["So", "the", "menu", "bar", "app", "crashed", "again."].enumerated().map { index, word in
      SpokenWord(word: word, start: Double(index) * 0.4, end: Double(index) * 0.4 + 0.35)
    }
    func render(_ view: some View, _ name: String) throws -> Data {
      let renderer = ImageRenderer(content: view.frame(width: 420).padding().background(Color.white))
      renderer.scale = 2
      let image = try XCTUnwrap(renderer.nsImage)
      let data = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
      try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("karaoke-\(name).png"))
      return data
    }
    let idle = try render(TranscriptView(transcript: transcript, isPlaying: false, onPlay: {}, onCopy: {}, onDelete: {}), "idle")
    let playing = try render(
      TranscriptView(transcript: transcript, isPlaying: true, playingWords: words, playbackTime: 1.3, onPlay: {}, onCopy: {}, onDelete: {}),
      "playing"
    )
    XCTAssertNotEqual(idle, playing)
  }
}
