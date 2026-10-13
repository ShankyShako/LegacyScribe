import Foundation
import HexCore
import XCTest

@testable import Hex

/// Loads the real Cohere checkpoint in the app process (MLX + bundled metallib) and transcribes
/// a fixture clip. Skipped when the model or the lsbench fixtures aren't on this machine.
final class CohereClientTests: XCTestCase {
  func testTranscribesFixtureClip() async throws {
    let client = CohereClient()
    let model = CohereModel.fourBit.identifier
    let available = await client.isModelAvailable(model)
    try XCTSkipUnless(available, "Cohere 4-bit not downloaded")
    let clip = try URL.hexApplicationSupport.appendingPathComponent("fixtures/say/03-tech.wav")
    try XCTSkipUnless(FileManager.default.fileExists(atPath: clip.path), "no lsbench fixtures")

    try await client.ensureLoaded(modelName: model) { _ in }
    let start = ContinuousClock.now
    let text = try await client.transcribe(clip, modelName: model)
    let elapsed = ContinuousClock.now - start

    XCTAssertTrue(text.localizedCaseInsensitiveContains("benchmark"), text)
    XCTAssertTrue(text.localizedCaseInsensitiveContains("Parakeet"), text)
    XCTAssertLessThan(elapsed, .seconds(2), "7.5 s clip took \(elapsed)")
  }
}
