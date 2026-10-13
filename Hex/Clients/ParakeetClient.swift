import Foundation
import HexCore

#if canImport(FluidAudio)
import FluidAudio

actor ParakeetClient {
  private var asr: AsrManager?
  private var models: AsrModels?
  private var currentVariant: ParakeetModel?
  private let logger = HexLog.parakeet

  func isModelAvailable(_ modelName: String) async -> Bool {
    guard let variant = ParakeetModel(rawValue: modelName) else {
      logger.error("Unknown Parakeet variant requested: \(modelName)")
      return false
    }
    if currentVariant == variant, asr != nil { return true }

    guard let directory = try? cacheDirectory(for: variant) else { return false }
    let available = AsrModels.modelsExist(
      at: directory,
      version: variant.asrVersion
    )
    if available {
      logger.notice("Found Parakeet cache at \(directory.path)")
    } else {
      logger.debug("No Parakeet cache detected variant=\(variant.identifier) path=\(directory.path)")
    }
    return available
  }

  func ensureLoaded(modelName: String, progress: @escaping (Progress) -> Void) async throws {
    guard let variant = ParakeetModel(rawValue: modelName) else {
      throw NSError(
        domain: "Parakeet",
        code: -4,
        userInfo: [NSLocalizedDescriptionKey: "Unsupported Parakeet variant: \(modelName)"]
      )
    }
    if currentVariant == variant, asr != nil { return }
    if currentVariant != variant {
      asr = nil
      models = nil
    }
    let t0 = Date()
    logger.notice("Starting Parakeet load variant=\(variant.identifier)")
    let p = Progress(totalUnitCount: 100)
    p.completedUnitCount = 1
    progress(p)

    // Best-effort progress polling while FluidAudio downloads
    let modelDirectory = try cacheDirectory(for: variant)
    let pollTask = Task {
      while p.completedUnitCount < 95 {
        try? await Task.sleep(nanoseconds: 250_000_000)
        if let size = directorySize(modelDirectory) {
          let target: Double = 650 * 1024 * 1024 // ~650MB
          let frac = max(0.0, min(1.0, Double(size) / target))
          p.completedUnitCount = Int64(5 + frac * 90)
          progress(p)
        }
        if Task.isCancelled { break }
      }
    }
    defer { pollTask.cancel() }

    // Download + load the requested variant (returns when all assets are present)
    let models = try await AsrModels.downloadAndLoad(to: modelDirectory, version: variant.asrVersion)
    self.models = models
    let manager = AsrManager(config: .init(), models: models)
    self.asr = manager
    self.currentVariant = variant
    p.completedUnitCount = 100
    progress(p)
    logger.notice("Parakeet ensureLoaded completed in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
  }

  private func directorySize(_ dir: URL) -> UInt64? {
    let fm = FileManager.default
    guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: .skipsHiddenFiles) else { return nil }
    var total: UInt64 = 0
    for case let url as URL in en {
      if let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), vals.isRegularFile == true {
        total &+= UInt64(vals.fileSize ?? 0)
      }
    }
    return total
  }

  /// `<Models/fluidaudio>/<repo-folder>`. Throws rather than falling back to FluidAudio's default
  /// folder, which is shared with other apps and must never be written to or deleted from.
  private func cacheDirectory(for variant: ParakeetModel) throws -> URL {
    let folder = AsrModels.defaultCacheDirectory(for: variant.asrVersion).lastPathComponent
    return try URL.hexParakeetModelsDirectory.appendingPathComponent(folder, isDirectory: true)
  }

  func transcribe(_ url: URL) async throws -> String {
    guard let asr else { throw NSError(domain: "Parakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "Parakeet not initialized"]) }
    let t0 = Date()
    logger.notice("Transcribing with Parakeet file=\(url.lastPathComponent)")
    var decoderState = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    let result = try await asr.transcribe(url, decoderState: &decoderState)
    logger.info("Parakeet transcription finished in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    return result.text
  }

  /// The words Parakeet hears in `url`, each with the time its tokens were decoded at.
  func timedWords(_ url: URL) async throws -> [SpokenWord] {
    guard let asr else { throw NSError(domain: "Parakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "Parakeet not initialized"]) }
    var decoderState = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    let result = try await asr.transcribe(url, decoderState: &decoderState)
    return WordMatcher.words(fromPieces: (result.tokenTimings ?? []).map { ($0.token, $0.startTime, $0.endTime) })
  }

  /// Deletes this variant's model folder and resets state. Only our own `Models/fluidaudio`
  /// folder is touched: unsandboxed, `~/Library/Application Support/FluidAudio` and
  /// `~/.cache` are shared with other FluidAudio apps.
  func deleteCaches(modelName: String) async throws {
    guard let variant = ParakeetModel(rawValue: modelName) else { return }
    let directory = try cacheDirectory(for: variant)
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try FileManager.default.removeItem(at: directory)

    // Reset live objects so a future download can proceed cleanly
    self.asr = nil
    self.models = nil
    if currentVariant == variant {
      currentVariant = nil
    }
  }
}

private extension ParakeetModel {
  var asrVersion: AsrModelVersion {
    switch self {
    case .englishV2: return .v2
    case .multilingualV3: return .v3
    }
  }
}

#else

actor ParakeetClient {
  func isModelAvailable(_ modelName: String) async -> Bool { false }
  func ensureLoaded(modelName: String, progress: @escaping (Progress) -> Void) async throws {
    throw NSError(
      domain: "Parakeet",
      code: -2,
      userInfo: [NSLocalizedDescriptionKey: "Parakeet support not linked. Add Swift Package: https://github.com/FluidInference/FluidAudio.git and link FluidAudio to Hex."]
    )
  }
  func transcribe(_ url: URL) async throws -> String { throw NSError(domain: "Parakeet", code: -3, userInfo: [NSLocalizedDescriptionKey: "Parakeet not available"]) }
  func timedWords(_ url: URL) async throws -> [SpokenWord] { throw NSError(domain: "Parakeet", code: -3, userInfo: [NSLocalizedDescriptionKey: "Parakeet not available"]) }
  func deleteCaches(modelName: String) async throws {}
}

#endif
