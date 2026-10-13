import CryptoKit
import Foundation
import HexCore

/// Downloads files of a Hugging Face model repository into a folder. Each file goes to a temp file, LFS files
/// are checked against their SHA-256, then moved into place, so a broken download never looks complete and a
/// stopped one picks up at the first missing file.
enum HuggingFaceDownloader {
  struct RepoFile: Decodable {
    struct LFS: Decodable { var oid: String }
    var type: String
    var path: String
    var size: Int64
    var lfs: LFS?
    var sha256: String? { lfs?.oid }
  }

  enum Failure: Error, LocalizedError {
    case checksumMismatch(String)
    case nothingToDownload(String)

    var errorDescription: String? {
      switch self {
      case let .checksumMismatch(file): "\(file) failed its checksum; download it again"
      case let .nothingToDownload(repository): "\(repository) has none of the files the model needs"
      }
    }
  }

  static func files(of repository: String) async throws -> [RepoFile] {
    let url = URL(string: "https://huggingface.co/api/models/\(repository)/tree/main")!
    let (data, response) = try await URLSession.shared.data(from: url)
    try ChatCompletionAPI.checkStatus((response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    return try JSONDecoder().decode([RepoFile].self, from: data).filter { $0.type == "file" }
  }

  /// Fetches the files `wanted` accepts that aren't in `directory` yet. `progress` gets 0…1 over all of them.
  static func download(
    _ repository: String,
    to directory: URL,
    wanted: (String) -> Bool,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let listing = try await files(of: repository).filter { wanted($0.path) }
    guard !listing.isEmpty else { throw Failure.nothingToDownload(repository) }
    let totalBytes = max(1, listing.reduce(0) { $0 + $1.size })
    var doneBytes: Int64 = 0

    for file in listing {
      try Task.checkCancellation()
      let destination = directory.appendingPathComponent(file.path)
      if FileManager.default.fileExists(atPath: destination.path) {
        doneBytes += file.size
        continue
      }
      let source = URL(string: "https://huggingface.co/\(repository)/resolve/main/\(file.path)")!
      HexLog.models.notice("Downloading \(repository, privacy: .public)/\(file.path, privacy: .public) (\(file.size / 1_048_576) MB)")
      let base = doneBytes
      let reporter = ThrottledProgress(progress)
      let (temporary, response) = try await URLSession.shared.download(from: source, delegate: DownloadProgress { written in
        reporter.report(Double(base + written) / Double(totalBytes))
      })
      if let status = (response as? HTTPURLResponse)?.statusCode, !(200 ..< 300).contains(status) {
        try? FileManager.default.removeItem(at: temporary)
        throw ChatCompletionAPI.Failure.http(status: status, body: "downloading \(file.path)")
      }
      // Move out of the system temp location right away; it may be cleaned up at any time.
      let partial = destination.appendingPathExtension("partial")
      try? FileManager.default.removeItem(at: partial)
      try FileManager.default.moveItem(at: temporary, to: partial)
      if let expected = file.sha256 {
        guard try sha256(of: partial) == expected else {
          try? FileManager.default.removeItem(at: partial)
          throw Failure.checksumMismatch(file.path)
        }
      }
      try FileManager.default.moveItem(at: partial, to: destination)
      doneBytes += file.size
      progress(Double(doneBytes) / Double(totalBytes))
    }
  }

  static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

/// The delegate fires for every packet; a progress bar needs a step every half percent.
private final class ThrottledProgress: @unchecked Sendable {
  private let lock = NSLock()
  private var last = -1.0
  private let forward: @Sendable (Double) -> Void

  init(_ forward: @escaping @Sendable (Double) -> Void) { self.forward = forward }

  func report(_ fraction: Double) {
    lock.lock()
    let due = fraction - last >= 0.005
    if due { last = fraction }
    lock.unlock()
    if due { forward(fraction) }
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
