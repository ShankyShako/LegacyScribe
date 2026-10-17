@preconcurrency import AVFoundation
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import Speech

/// The live caption: the dictation's own 16 kHz samples (`RecordingClient.recordingSamples`) go to a per-dictation
/// `SpeechAnalyzer` with volatile + fast results, and every change of what the caption should say comes out as a
/// `CaptionText`. Nothing here is kept or pasted; History gets the real engine's text. Streaming ends when the
/// sample stream does or when the consumer stops iterating (the reducer cancels at key-up).
@DependencyClient
struct LiveCaptionClient {
  /// False when Apple's English model isn't installed (the caption is skipped; nothing is downloaded here).
  var isAvailable: @Sendable () async -> Bool = { false }
  var captions: @Sendable (AsyncStream<[Float]>) -> AsyncStream<CaptionText> = { _ in AsyncStream { $0.finish() } }
}

extension LiveCaptionClient: DependencyKey {
  static var liveValue: Self {
    Self(
      isAvailable: { await AppleSpeech.isInstalled() },
      captions: { samples in
        AsyncStream { output in
          let task = Task { await LiveCaptionStreamer.run(samples: samples, output: output) }
          output.onTermination = { _ in task.cancel() }
        }
      }
    )
  }

  static var testValue: Self { Self(isAvailable: { false }, captions: { _ in AsyncStream { $0.finish() } }) }
}

extension DependencyValues {
  var liveCaption: LiveCaptionClient {
    get { self[LiveCaptionClient.self] }
    set { self[LiveCaptionClient.self] = newValue }
  }
}

/// Mirrors `LiveStreamBench.streamClip`: `SpeechTranscriber` with `.volatileResults + .fastResults`, 100 ms inputs.
enum LiveCaptionStreamer {
  /// Samples per `AnalyzerInput` (100 ms at 16 kHz).
  static let batchSamples = 1_600

  static func run(samples: AsyncStream<[Float]>, output: AsyncStream<CaptionText>.Continuation) async {
    defer { output.finish() }
    do {
      let transcriber = SpeechTranscriber(
        locale: Locale(identifier: "en-US"),
        transcriptionOptions: [],
        reportingOptions: [.volatileResults, .fastResults],
        attributeOptions: []
      )
      let analyzer = SpeechAnalyzer(modules: [transcriber])
      guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
            let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: source, to: format)
      else {
        HexLog.transcription.error("Live caption: no audio format for SpeechAnalyzer")
        return
      }
      try await analyzer.prepareToAnalyze(in: format)
      let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

      let collector = Task {
        var caption = LiveCaption()
        var last = CaptionText(words: [], dimLast: false)
        var signalled = false
        do {
          for try await result in transcriber.results {
            let range = result.range
            caption.apply(CaptionResult(
              isFinal: result.isFinal,
              text: String(result.text.characters),
              start: range.start.seconds,
              end: range.end.seconds
            ))
            let display = caption.display
            guard display != last else { continue }
            last = display
            if !signalled, !display.isEmpty {
              signalled = true
              HexLog.latencySignposter.emitEvent("captionFirstWord")
            }
            output.yield(display)
          }
        } catch is CancellationError {
        } catch {
          HexLog.transcription.error("Live caption results ended: \(error.localizedDescription, privacy: .public)")
        }
      }

      try await analyzer.start(inputSequence: inputs)

      var pending: [Float] = []
      func flush(_ count: Int) {
        let piece = Array(pending.prefix(count))
        pending.removeFirst(piece.count)
        if let buffer = convert(piece, with: converter, to: format) {
          inputContinuation.yield(AnalyzerInput(buffer: buffer))
        }
      }
      for await chunk in samples {
        pending += chunk
        while pending.count >= batchSamples { flush(batchSamples) }
      }
      if !Task.isCancelled, !pending.isEmpty { flush(pending.count) }
      inputContinuation.finish()
      // Never `finalizeAndFinish`: the final text isn't wanted, and the bench saw it hang at the very end.
      await analyzer.cancelAndFinishNow()
      collector.cancel()
    } catch {
      HexLog.transcription.error("Live caption failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private static func convert(_ samples: [Float], with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
    guard let source = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
          let channel = source.floatChannelData?[0],
          let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count) + 64)
    else { return nil }
    source.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
    nonisolated(unsafe) var supplied = false
    var error: NSError?
    converter.convert(to: converted, error: &error) { _, status in
      if supplied { status.pointee = .noDataNow; return nil }
      supplied = true
      status.pointee = .haveData
      return source
    }
    return error == nil && converted.frameLength > 0 ? converted : nil
  }
}
