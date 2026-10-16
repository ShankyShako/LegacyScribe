import FluidAudio
import Foundation
import HexCore
import MLX
import MLXAudioSTT

/// Cohere Transcribe via MLX: ~1.5 GB while loaded (4-bit), so it's loaded per dictation and unloaded after.
/// Cohere has no timestamps and no free-text prompt; vocabulary is handled by the LLM rewrite.
actor CohereClient {
  private var model: CohereTranscribeModel?
  private var currentVariant: CohereModel?
  private let converter = AudioConverter()
  private let voice = NotesVoiceDetector()
  private let logger = HexLog.transcription

  /// Drops the weights and MLX's buffer cache. Metal hands the memory back to the system a few seconds
  /// later (1.66 GB → 57 MB in lsbench); loading again takes ~0.4 s from a warm file cache.
  func unload() {
    guard model != nil else { return }
    model = nil
    currentVariant = nil
    Memory.clearCache()
    logger.notice("Cohere unloaded")
  }

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
    // Building the model draws ~900 random keys lazily; unevaluated, the key chain is kept forever.
    eval(MLXRandom.globalState)
    model = loaded
    currentVariant = variant
    overall.completedUnitCount = 100
    progress(overall)
    logger.notice("Cohere \(variant.identifier, privacy: .public) loaded and warmed in \(String(describing: ContinuousClock.now - start), privacy: .public)")
  }

  /// Loads the model first if it was unloaded, in the same actor turn, so an unload can't land between.
  func transcribe(_ url: URL, modelName: String) async throws -> String {
    try await transcribe(samples: try converter.resampleAudioFile(url), modelName: modelName)
  }

  /// Dictation: only the speech Silero VAD finds goes to Cohere (stretches joined as in Notes, `NotesSpeech`).
  /// Given silence or a near-silent stretch Cohere writes "Thank you.": 14 of 16 History dictations ending
  /// that way had no "thank you" in them, and gating removed 13 (bench-results). No speech → empty text,
  /// which pastes nothing. A recording that never gets louder than `NotesSpeech.dictationFloorDecibels` is
  /// empty too, because Silero sometimes calls a quiet room speech. If the VAD can't load (offline before its
  /// first download), all of it goes.
  func transcribeSpeech(_ url: URL, modelName: String) async throws -> String {
    var samples = try converter.resampleAudioFile(url)
    guard !NotesSpeech.isBelowDictationFloor(samples) else { return "" }
    do {
      guard let speech = NotesSpeech.joined(samples, ranges: try await voice.speechRanges(in: samples)) else { return "" }
      samples = speech
    } catch {
      logger.error("Dictation speech detection failed, transcribing all of it: \(error.localizedDescription, privacy: .public)")
    }
    return try await transcribe(samples: samples, modelName: modelName)
  }

  /// 16 kHz mono samples, cut where `CohereChunks` says; the pieces' transcripts are one dictation.
  func transcribe(samples: [Float], modelName: String) async throws -> String {
    try await ensureLoaded(modelName: modelName) { _ in }
    guard let model else { throw CohereError.notLoaded }
    return CohereChunks.ranges(samples, sampleRate: 16_000).map { range in
      model.generate(audio: MLXArray(Array(samples[range])), generationParameters: Self.parameters).text
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    .filter { !$0.isEmpty }
    .joined(separator: " ")
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
  /// most of the speech and loops on a sentence. `CohereChunks` cuts the audio into pieces of at most 30 s,
  /// so mlx-audio's own splitter (which left slivers that came back as "Thank you.") never runs.
  private static let parameters = STTGenerateParameters(language: "en", chunkDuration: Float(CohereChunks.singlePassSeconds) + 5)

  private func directory(for variant: CohereModel) throws -> URL {
    try URL.hexMLXModelsDirectory.appendingPathComponent(variant.repository, isDirectory: true)
  }

  // MARK: - Download

  private func download(_ variant: CohereModel, to directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
    try await HuggingFaceDownloader.download(
      variant.repository,
      to: directory,
      wanted: { CohereModel.requiredFiles.contains($0) },
      progress: progress
    )
  }
}

enum CohereError: Error, LocalizedError {
  case unknownModel(String)
  case notLoaded

  var errorDescription: String? {
    switch self {
    case let .unknownModel(name): "Unknown Cohere model: \(name)"
    case .notLoaded: "Cohere model used before it was loaded"
    }
  }
}
