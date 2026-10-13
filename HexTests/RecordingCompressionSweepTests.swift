import AVFoundation
import ComposableArchitecture
import Foundation
import HexCore
import XCTest

@testable import Hex

/// Recordings kept as WAV are converted to FLAC and their entries repointed; pins (by entry ID) still hold.
/// Only `compress` is run here: the full sweep also clears unreferenced files in the real `Recordings/`.
@MainActor
final class RecordingCompressionSweepTests: XCTestCase {
  func testWAVRecordingsBecomeFLACAndEntriesFollow() throws {
    let folder = FileManager.default.temporaryDirectory.appending(component: "sweep-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let wav = try writeWAV(folder.appending(component: "a.wav"))
    let other = try writeWAV(folder.appending(component: "b.wav"))
    let pinned = Transcript(timestamp: Date(timeIntervalSinceNow: -90 * 86400), text: "pinned", audioPath: wav, duration: 1)
    let skipped = Transcript(timestamp: Date(), text: "not asked for", audioPath: other, duration: 1)
    @Shared(.transcriptionHistory) var history: TranscriptionHistory
    $history.withLock { $0.history = [pinned, skipped] }
    defer { $history.withLock { $0.history = [] } }

    AudioRetentionSweep.compress(ids: [pinned.id])

    let entry = history.history.first { $0.id == pinned.id }
    XCTAssertEqual(entry?.audioPath.lastPathComponent, "a.flac")
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(component: "a.flac").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
    XCTAssertEqual(history.history.first { $0.id == skipped.id }?.audioPath, other)

    // The entry's ID is unchanged, so a sent edit still pins its recording.
    let edit = SentEdit(timestamp: Date(), transcriptID: pinned.id, bundleID: nil, appName: nil, mode: nil, recognized: "pinned", pasted: "pinned", sent: "Pinned!")
    XCTAssertTrue(AudioRetention.pinned(by: [edit]).contains(pinned.id))
    XCTAssertEqual(AudioRetention.expired(history.history, pinned: [pinned.id], days: 30, now: Date()), [])
  }

  private func writeWAV(_ url: URL) throws -> URL {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
    buffer.frameLength = 16000
    for index in 0 ..< 16000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) / 9) * 0.5) }
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
    return url
  }
}
