import CryptoKit
import FluidAudio
import Foundation
import HexCore
import MLX
import MLXAudioSTT

/// Cohere Transcribe via MLX, kept resident after the first load (~1.4 GB for 4-bit).
/// Cohere has no timestamps and no free-text prompt; vocabulary is handled by the LLM rewrite.
actor CohereClient {
  private var model: CohereTranscribeModel?
  private var currentVariant: CohereModel?
  private let converter = AudioConverter()
  private let logger = HexLog.transcription

  func isModelAvailable(_ modelName: String) -> Bool {
    guard let variant = CohereModel(rawValue: modelName) else { return false }
    if currentVariant == variant, model != nil { return true }
    guard let directory = try? directory(for: variant) else { return false }
    return CohereModel.requiredFiles.allSatisfy {
      FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
    }
  }

  func ensureLoaded(modelName: String, progress: @escaping (Progress) -> Void) async throws {
    guard let variant = CohereModel(rawValue: modelName) else {
      throw CohereError.unknownModel(modelName)
    }
    if currentVariant == variant, model != nil { return }
    model = nil
    currentVariant = nil

    let directory = try directory(for: variant)
    let overall = Progress(totalUnitCount: 100)
    progress(overall)
    if !isModelAvailable(modelName) {
      try await download(variant, to: directory) { fraction in
        overall.completedUnitCount = Int64(fraction * 90)
        progress(overall)
      }
    }

    let start = ContinuousClock.now
    let loaded = try CohereTranscribeModel.fromDirectory(directory)
    // First inference compiles Metal kernels; do it now so the first dictation isn't slow.
    _ = loaded.generate(audio: MLXArray([Float](repeating: 0, count: 16_000)), generationParameters: Self.parameters)
    model = loaded
    currentVariant = variant
    overall.completedUnitCount = 100
    progress(overall)
    logger.notice("Cohere \(variant.identifier, privacy: .public) loaded and warmed in \(String(describing: ContinuousClock.now - start), privacy: .public)")
  }

  func transcribe(_ url: URL) throws -> String {
    guard let model else { throw CohereError.notLoaded }
    let samples = try converter.resampleAudioFile(url)
    // Chunk transcripts come back joined by newlines; they're one dictation.
    return model.generate(audio: MLXArray(samples), generationParameters: Self.parameters).text
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func deleteCaches(modelName: String) throws {
    guard let variant = CohereModel(rawValue: modelName) else { return }
    if currentVariant == variant {
      model = nil
      currentVariant = nil
    }
    let directory = try directory(for: variant)
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
  }

  /// Cohere was trained on clips up to 35 s (`max_audio_clip_s`); fed a longer one in a single pass it drops
  /// most of the speech and loops on a sentence. The splitter cuts at the quietest point within ±5 s of each
  /// 25 s mark, so every chunk stays at or under 30 s.
  static let chunkSeconds: Float = 25
  private static let parameters = STTGenerateParameters(language: "en", chunkDuration: chunkSeconds)

  private func directory(for variant: CohereModel) throws -> URL {
    try URL.hexMLXModelsDirectory.appendingPathComponent(variant.repository, isDirectory: true)
  }

  // MARK: - Download

  /// Fetches each missing file from Hugging Face into a temp file, checks LFS files against
  /// their SHA-256, then moves it into place, so a broken download never looks complete.
  private func download(_ variant: CohereModel, to directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let listing = try await Self.repositoryFiles(variant.repository)
    let wanted = listing.filter { CohereModel.requiredFiles.contains($0.path) }
    let totalBytes = max(1, wanted.reduce(0) { $0 + $1.size })
    var doneBytes: Int64 = 0

    for file in wanted {
      let destination = directory.appendingPathComponent(file.path)
      if FileManager.default.fileExists(atPath: destination.path) {
        doneBytes += file.size
        continue
      }
      let source = URL(string: "https://huggingface.co/\(variant.repository)/resolve/main/\(file.path)")!
      logger.notice("Downloading \(file.path, privacy: .public) (\(file.size / 1_048_576) MB)")
      let base = doneBytes
      let (temporary, _) = try await URLSession.shared.download(from: source, delegate: DownloadProgress { written in
        progress(Double(base + written) / Double(totalBytes))
      })
      // Move out of the system temp location right away; it may be cleaned up at any time.
      let partial = destination.appendingPathExtension("partial")
      try? FileManager.default.removeItem(at: partial)
      try FileManager.default.moveItem(at: temporary, to: partial)
      if let expected = file.sha256 {
        let actual = try Self.sha256(of: partial)
        guard actual == expected else {
          try? FileManager.default.removeItem(at: partial)
          throw CohereError.checksumMismatch(file.path)
        }
      }
      try FileManager.default.moveItem(at: partial, to: destination)
      doneBytes += file.size
      progress(Double(doneBytes) / Double(totalBytes))
    }
  }

  private struct RepoFile: Decodable {
    struct LFS: Decodable { var oid: String }
    var type: String
    var path: String
    var size: Int64
    var lfs: LFS?
    var sha256: String? { lfs?.oid }
  }

  private static func repositoryFiles(_ repository: String) async throws -> [RepoFile] {
    let url = URL(string: "https://huggingface.co/api/models/\(repository)/tree/main")!
    let (data, _) = try await URLSession.shared.data(from: url)
    return try JSONDecoder().decode([RepoFile].self, from: data).filter { $0.type == "file" }
  }

  private static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  let onBytes: @Sendable (Int64) -> Void
  init(onBytes: @escaping @Sendable (Int64) -> Void) { self.onBytes = onBytes }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    onBytes(totalBytesWritten)
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

enum CohereError: Error, LocalizedError {
  case unknownModel(String)
  case notLoaded
  case checksumMismatch(String)

  var errorDescription: String? {
    switch self {
    case let .unknownModel(name): "Unknown Cohere model: \(name)"
    case .notLoaded: "Cohere model used before it was loaded"
    case let .checksumMismatch(file): "\(file) failed its checksum; download it again"
    }
  }
}
