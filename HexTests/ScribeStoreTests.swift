import Foundation
import HexCore
import XCTest

@testable import Hex

/// The move from JSON files to scribe.sqlite, checked against copies of this Mac's real files (skipped
/// where there are none), and word timings from the real Parakeet model.
final class ScribeStoreTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-import-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: folder)
  }

  private func copyOfRealFile(_ name: String) throws -> URL {
    let real = try URL.hexApplicationSupport.appendingPathComponent(name)
    try XCTSkipUnless(FileManager.default.fileExists(atPath: real.path), "no \(name) on this Mac")
    let copy = folder.appendingPathComponent(name)
    try FileManager.default.copyItem(at: real, to: copy)
    return copy
  }

  func testRealSentEditsImportUnchanged() throws {
    let url = try copyOfRealFile("sent_edits.json")
    let original = try JSONDecoder().decode(SentEditLog.self, from: Data(contentsOf: url))
    let store = try ScribeStore(path: folder.appendingPathComponent("scribe.sqlite").path)

    XCTAssertEqual(try store.importSentEditsFile(url), original.edits.count)
    XCTAssertEqual(try store.sentEdits(), original.edits.sorted { $0.timestamp < $1.timestamp })
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".imported"))
  }

  func testRealHistoryImportsUnchanged() throws {
    let url = try copyOfRealFile("transcription_history.json")
    let original = try JSONDecoder().decode(TranscriptionHistory.self, from: Data(contentsOf: url))
    let store = try ScribeStore(path: folder.appendingPathComponent("scribe.sqlite").path)

    XCTAssertEqual(try store.importHistoryFile(url), original.history.count)
    XCTAssertEqual(try store.transcripts(), original.history.sorted { $0.timestamp > $1.timestamp })
  }

  /// Parakeet's timings land on a transcript Cohere might have written: same words, different spelling.
  func testParakeetPlacesAnotherEnginesWords() async throws {
    let clip = try URL.hexApplicationSupport.appendingPathComponent("fixtures/say/03-tech.wav")
    try XCTSkipUnless(FileManager.default.fileExists(atPath: clip.path), "no lsbench fixtures")
    let client = TranscriptionClientLive()
    let model = ParakeetModel.englishV2.identifier
    let available = await client.isModelDownloaded(model)
    try XCTSkipUnless(available, "Parakeet v2 not downloaded")

    let reference = try String(contentsOf: clip.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
    let words = reference.split(whereSeparator: \.isWhitespace).map(String.init)
    let timed = try await client.timedWords(audio: clip, words: words, selectedModel: model)

    XCTAssertEqual(timed.map(\.word), words)
    XCTAssertEqual(timed.map(\.start), timed.map(\.start).sorted(), "starts must not go backwards")
    XCTAssertTrue(timed.allSatisfy { $0.end >= $0.start })
    XCTAssertLessThan(timed.last?.end ?? 99, 9, "a 7.5 s clip")
    XCTAssertGreaterThan(timed.last?.start ?? 0, 4, "the last word comes near the end")
  }
}
