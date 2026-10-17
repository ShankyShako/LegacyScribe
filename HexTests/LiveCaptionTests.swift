import AVFoundation
import ComposableArchitecture
import Foundation
import HexCore
import XCTest

@testable import Hex

/// The live caption (DESIGN.md "Live caption"): the reducer wiring with a test client, and a fixture WAV fed at
/// 1x through the real stream -> `LiveCaptionClient` -> `LiveCaption.apply` -> `TranscriptionFeature` path.
@MainActor
final class LiveCaptionTests: XCTestCase {
  // MARK: Reducer wiring

  func testCaptionUpdatesWhileRecordingAndClearsAtKeyUp() async {
    let first = CaptionText(words: ["Can", "you"], dimLast: true)
    let second = CaptionText(words: ["Can", "you", "move"], dimLast: true)
    let store = makeStore(captionEnabled: true) {
      $0.liveCaption = LiveCaptionClient(
        isAvailable: { true },
        captions: { _ in AsyncStream { continuation in continuation.yield(first); continuation.yield(second); continuation.finish() } }
      )
    }

    await store.send(.microphoneReady)
    await store.receive(\.captionUpdated, first) { $0.caption = first }
    await store.receive(\.captionUpdated, second) { $0.caption = second }
    await store.send(.stopRecording) { $0.isRecording = false; $0.caption = nil }
    await store.finish()
  }

  func testNoCaptionWhenTheSettingIsOff() async {
    let store = makeStore(captionEnabled: false) {
      $0.liveCaption = LiveCaptionClient(
        isAvailable: { true },
        captions: { _ in AsyncStream { continuation in
          continuation.yield(CaptionText(words: ["never"], dimLast: false)); continuation.finish()
        } }
      )
    }
    await store.send(.microphoneReady)
    await store.finish()
    XCTAssertNil(store.state.caption)
  }

  func testEscClearsTheCaption() async {
    let shown = CaptionText(words: ["Hello"], dimLast: true)
    let store = makeStore(captionEnabled: true) {
      $0.liveCaption = LiveCaptionClient(
        isAvailable: { true },
        captions: { _ in AsyncStream { continuation in continuation.yield(shown) } }  // stays open
      )
    }
    await store.send(.microphoneReady)
    await store.receive(\.captionUpdated, shown) { $0.caption = shown }
    await store.send(.cancel) { $0.isRecording = false; $0.caption = nil }
    await store.finish()
  }

  func testANotesTapCancelsTheCaptionBeforeAnyWord() async {
    let store = makeStore(captionEnabled: true) {
      $0.liveCaption = LiveCaptionClient(
        isAvailable: { true },
        captions: { _ in AsyncStream { _ in } }  // no words yet
      )
      $0.notes.start = { "2026-10-17-100000" }
      $0.recording.stopRecording = { .ignored(.noActiveRecording) }
    }
    store.exhaustivity = .off
    await store.send(.microphoneReady)
    await store.send(.notesTapped)
    XCTAssertNil(store.state.caption)
    XCTAssertFalse(store.state.isRecording)
    await store.skipInFlightEffects()
  }

  // MARK: Fixture feed

  /// Feeds fixture clips to the live caption at 1x, in tap-sized chunks, and logs the caption over time.
  /// Apple's fast results arrive about once a second (bench-results, "Live Apple Speech"), so the first word's
  /// delay depends on where the onset falls in that second: the median over the clips must be within 1.2 s of
  /// the speech onset and none later than 1.6 s. Two seconds of silence follow each clip (a user pausing before
  /// key-up); the settled caption must be close to the clip's text.
  func testFixtureClipsAreCaptionedInRealTime() async throws {
    let installed = await AppleSpeech.isInstalled()
    try XCTSkipUnless(installed, "Apple's English speech model isn't installed")
    let folder = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/LegacyScribe/fixtures/me")
    var report: [String] = []
    var delays: [Double] = []
    var totalErrors = 0, totalWords = 0
    for name in ["01", "02", "03", "04", "05"] {
      let wav = folder.appendingPathComponent("\(name).wav")
      guard let reference = try? String(contentsOf: folder.appendingPathComponent("\(name).txt"), encoding: .utf8) else {
        throw XCTSkip("fixture \(name) missing")
      }
      let clip = try Self.loadSamples(wav)
      let onset = Self.speechOnset(clip)
      let samples = clip + [Float](repeating: 0, count: 32_000)

      let (stream, feed) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
      let store = Store(initialState: makeState(captionEnabled: true)) {
        TranscriptionFeature()
      } withDependencies: {
        $0.recording.recordingSamples = { stream }
        $0.transcription.prewarm = { _ in }
        $0.localLLM.prewarm = { _ in }
        $0.liveCaption = .liveValue
        $0.date.now = Date(timeIntervalSince1970: 1_005)
        $0.sleepManagement.allowSleep = {}
        $0.localLLM.unload = {}
        $0.soundEffects.play = { _ in }
        $0.recording.stopRecording = { .ignored(.noActiveRecording) }
      }
      store.send(.microphoneReady)

      let clock = ContinuousClock()
      let t0 = clock.now
      var log: [(t: Double, text: String)] = []
      var last = ""
      func sample() {
        let text = store.caption?.text ?? ""
        if text != last {
          last = text
          let elapsed = (clock.now - t0).components
          log.append((Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18, text))
        }
      }
      let chunk = 2_048  // a tap buffer
      var offset = 0
      while offset < samples.count {
        let end = min(offset + chunk, samples.count)
        feed.yield(Array(samples[offset ..< end]))
        offset = end
        try await clock.sleep(until: t0 + .seconds(Double(offset) / 16_000), tolerance: .milliseconds(5))
        sample()
      }
      let settleUntil = clock.now + .milliseconds(300)
      while clock.now < settleUntil { try await clock.sleep(for: .milliseconds(25)); sample() }
      feed.finish()
      store.send(.cancel)  // key-up and Esc both clear the caption (the stopRecording path is covered above)

      let firstWord = log.first { !$0.text.isEmpty }?.t
      let delay = firstWord.map { $0 - onset }
      report.append("clip \(name): onset \(String(format: "%.2f", onset)) s, first word at \(firstWord.map { String(format: "%.2f", $0) } ?? "never") s (+\(delay.map { String(format: "%.2f", $0) } ?? "-") s), \(log.count) updates")
      for entry in log { report.append(String(format: "  %5.2f s  %@", entry.t, entry.text)) }
      let errors = Self.wordErrors(reference: reference, hypothesis: last)
      report.append("  final: \(last)\n  reference: \(reference.trimmingCharacters(in: .whitespacesAndNewlines))\n  word errors \(errors.errors)/\(errors.referenceWords)")
      totalErrors += errors.errors; totalWords += errors.referenceWords

      delays.append(try XCTUnwrap(delay, "clip \(name): no caption words"))
      XCTAssertNil(store.caption, "nothing stays on screen after key-up")
    }
    let median = delays.sorted()[delays.count / 2]
    report.append("median first word \(String(format: "%.2f", median)) s after onset, max \(String(format: "%.2f", delays.max() ?? 0)) s; word errors \(totalErrors)/\(totalWords) (digits and contractions count)")
    let text = report.joined(separator: "\n")
    print("LIVE CAPTION FIXTURE FEED\n\(text)")
    try? text.write(toFile: "/tmp/live-caption-feed.log", atomically: true, encoding: .utf8)
    XCTAssertLessThanOrEqual(median, 1.2, "median first word too late")
    XCTAssertLessThanOrEqual(delays.max() ?? 0, 1.6, "a first word came too late")
    XCTAssertLessThanOrEqual(Double(totalErrors) / Double(totalWords), 0.25, "the caption differs from the clips")
  }

  /// Private mode keeps the caption: it runs on-device with no socket and no blocked request.
  func testCaptionOpensNoSocketInPrivateMode() async throws {
    let installed = await AppleSpeech.isInstalled()
    try XCTSkipUnless(installed, "Apple's English speech model isn't installed")
    let wav = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/LegacyScribe/fixtures/me/02.wav")
    guard FileManager.default.fileExists(atPath: wav.path) else { throw XCTSkip("fixture missing") }
    let samples = try Self.loadSamples(wav)
    NetworkPolicy.install()
    NetworkPolicy.setPrivate(true)
    defer { NetworkPolicy.setPrivate(false) }
    let blockedBefore = NetworkPolicy.blockedRequests
    let before = PrivateModeTests.internetSockets()
    let watcher = Task.detached { () -> Set<Int32> in
      var opened = Set<Int32>()
      while !Task.isCancelled {
        opened.formUnion(PrivateModeTests.internetSockets().subtracting(before))
        try? await Task.sleep(for: .milliseconds(10))
      }
      return opened
    }
    let (stream, feed) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
    var shown = ""
    let task = Task { @MainActor in
      for await caption in LiveCaptionClient.liveValue.captions(stream) { shown = caption.text }
    }
    var offset = 0
    while offset < samples.count {
      let end = min(offset + 16_000, samples.count)   // 1 s at a time, faster than real time: a socket check, not timing
      feed.yield(Array(samples[offset ..< end])); offset = end
      try await Task.sleep(for: .milliseconds(300))
    }
    try await Task.sleep(for: .seconds(1))
    feed.finish()
    await task.value
    watcher.cancel()
    let opened = await watcher.value
    XCTAssertFalse(shown.isEmpty, "the caption should still work in Private mode")
    XCTAssertEqual(NetworkPolicy.blockedRequests, blockedBefore, "the caption tried the network")
    XCTAssertTrue(opened.isEmpty, "internet sockets opened during the caption: \(opened)")
  }

  // MARK: Budget (item 9; opt-in because it streams 60 s in real time)

  /// `LIVE_CAPTION_BUDGET=1`: CPU of this process while a 60 s dictation streams to the caption (an upper bound for
  /// the app: the test's own polling is included), the main-actor cost of key-up with and without the caption, and
  /// how long the analyzer takes to shut down after the consumer stops (off the key-up path).
  func testCaptionBudget() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_CAPTION_BUDGET"] == "1", "set LIVE_CAPTION_BUDGET=1")
    let folder = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/LegacyScribe/fixtures/me")
    var speech: [Float] = []
    var index = 1
    while speech.count < 16_000 * 60 {
      speech += try Self.loadSamples(folder.appendingPathComponent(String(format: "%02d.wav", index)))
      speech += [Float](repeating: 0, count: 8_000)
      index = index % 15 + 1
    }
    speech = Array(speech.prefix(16_000 * 60))

    func cpuSeconds() -> Double {
      var usage = rusage()
      getrusage(RUSAGE_SELF, &usage)
      func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
      return s(usage.ru_utime) + s(usage.ru_stime)
    }
    var lines: [String] = []

    // 1. CPU over a 60 s dictation, through the reducer exactly as in the app.
    let (stream, feed) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
    let store = Store(initialState: makeState(captionEnabled: true)) {
      TranscriptionFeature()
    } withDependencies: {
      $0.recording.recordingSamples = { stream }
      $0.transcription.prewarm = { _ in }
      $0.localLLM.prewarm = { _ in }
      $0.liveCaption = .liveValue
      $0.date.now = Date(timeIntervalSince1970: 1_005)
      $0.sleepManagement.allowSleep = {}
      $0.localLLM.unload = {}
      $0.soundEffects.play = { _ in }
      $0.recording.stopRecording = { .ignored(.noActiveRecording) }
    }
    store.send(.microphoneReady)
    let clock = ContinuousClock()
    let cpu0 = cpuSeconds()
    let t0 = clock.now
    var offset = 0, updates = 0, last = ""
    while offset < speech.count {
      let end = min(offset + 2_048, speech.count)
      feed.yield(Array(speech[offset ..< end])); offset = end
      try await clock.sleep(until: t0 + .seconds(Double(offset) / 16_000), tolerance: .milliseconds(5))
      let text = store.caption?.text ?? ""
      if text != last { last = text; updates += 1 }
    }
    let wall = Double((clock.now - t0).components.seconds)
    let cpu = cpuSeconds() - cpu0
    lines.append(String(format: "60 s dictation: %.2f s of process CPU in %.1f s = %.1f%% of one core, %d caption changes", cpu, wall, 100 * cpu / wall, updates))

    // 2. Key-up on the main actor with the caption streaming (cancel stands in for stopRecording's cancel step).
    for enabled in [true, false] {
      var times: [Double] = []
      for _ in 0 ..< 10 {
        let (s, f) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        let local = Store(initialState: makeState(captionEnabled: enabled)) {
          TranscriptionFeature()
        } withDependencies: {
          $0.recording.recordingSamples = { s }
          $0.transcription.prewarm = { _ in }
          $0.localLLM.prewarm = { _ in }
          $0.liveCaption = .liveValue
          $0.date.now = Date(timeIntervalSince1970: 1_005)
          $0.sleepManagement.allowSleep = {}
          $0.localLLM.unload = {}
          $0.soundEffects.play = { _ in }
          $0.recording.stopRecording = { .ignored(.noActiveRecording) }
        }
        local.send(.microphoneReady)
        for k in 0 ..< 40 { f.yield(Array(speech[(k * 1_600) ..< ((k + 1) * 1_600)])); try await clock.sleep(for: .milliseconds(50)) }
        let a = clock.now
        local.send(.cancel)
        let b = clock.now
        let d = (b - a).components
        times.append((Double(d.seconds) + Double(d.attoseconds) / 1e18) * 1000)
        f.finish()
      }
      times.sort()
      lines.append(String(format: "key-up send on the main actor, caption %@: median %.3f ms, max %.3f ms (10 runs, 2 s of audio in)", enabled ? "on" : "off", times[5], times[9]))
    }

    // 3. Analyzer shutdown after the consumer stops (runs off the key-up path).
    var shutdowns: [Double] = []
    for _ in 0 ..< 5 {
      let (s, f) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
      let (outputs, output) = AsyncStream<CaptionText>.makeStream()
      _ = outputs
      let task = Task { await LiveCaptionStreamer.run(samples: s, output: output) }
      for k in 0 ..< 30 { f.yield(Array(speech[(k * 1_600) ..< ((k + 1) * 1_600)])); try await clock.sleep(for: .milliseconds(100)) }
      let a = clock.now
      task.cancel()
      await task.value
      let d = (clock.now - a).components
      shutdowns.append((Double(d.seconds) + Double(d.attoseconds) / 1e18) * 1000)
      f.finish()
    }
    shutdowns.sort()
    lines.append(String(format: "analyzer shutdown after cancel (off the key-up path): median %.0f ms, max %.0f ms (5 runs)", shutdowns[2], shutdowns[4]))
    let text = lines.joined(separator: "\n")
    print("LIVE CAPTION BUDGET\n\(text)")
    try? text.write(toFile: "/tmp/live-caption-budget.log", atomically: true, encoding: .utf8)
  }

  // MARK: Helpers

  private func makeState(captionEnabled: Bool) -> TranscriptionFeature.State {
    var state = TranscriptionFeature.State(
      hexSettings: Shared(value: HexSettings(superEnabled: false, liveCaptionEnabled: captionEnabled)),
      isRemappingScratchpadFocused: false,
      modelBootstrapState: Shared(value: .init(isModelReady: true)),
      transcriptionHistory: Shared(value: TranscriptionHistory())
    )
    state.isRecording = true
    state.recordingStartTime = Date(timeIntervalSince1970: 1_000)
    return state
  }

  private func makeStore(
    captionEnabled: Bool, dependencies: @escaping (inout DependencyValues) -> Void
  ) -> TestStoreOf<TranscriptionFeature> {
    let store = TestStore(initialState: makeState(captionEnabled: captionEnabled)) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_005)
      $0.continuousClock = TestClock()
      $0.recording.recordingSamples = { AsyncStream { $0.finish() } }
      $0.recording.stopRecording = { .ignored(.noActiveRecording) }
      $0.transcription.prewarm = { _ in }
      $0.localLLM.prewarm = { _ in }
      $0.localLLM.unload = {}
      $0.sleepManagement.allowSleep = {}
      $0.soundEffects.play = { _ in }
      dependencies(&$0)
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    return store
  }

  nonisolated static func loadSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
    try file.read(into: buffer)
    guard file.processingFormat.sampleRate != 16_000 || file.processingFormat.channelCount != 1 else {
      return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    let converter = AVAudioConverter(from: file.processingFormat, to: format)!
    let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / file.processingFormat.sampleRate) + 1_024)!
    nonisolated(unsafe) var supplied = false
    converter.convert(to: out, error: nil) { _, status in
      if supplied { status.pointee = .endOfStream; return nil }
      supplied = true; status.pointee = .haveData; return buffer
    }
    return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
  }

  /// Seconds until the first 20 ms block louder than 0.01 RMS (as `lsbench live`).
  nonisolated static func speechOnset(_ samples: [Float]) -> Double {
    let block = 320
    var start = 0
    while start + block <= samples.count {
      var sum: Float = 0
      for i in start ..< start + block { sum += samples[i] * samples[i] }
      if (sum / Float(block)).squareRoot() > 0.01 { return Double(start) / 16_000 }
      start += block
    }
    return 0
  }

  nonisolated static func words(_ text: String) -> [String] {
    text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
  }

  nonisolated static func wordErrors(reference: String, hypothesis: String) -> (errors: Int, referenceWords: Int) {
    let r = words(reference), h = words(hypothesis)
    var row = Array(0 ... h.count)
    for i in 1 ... max(r.count, 1) where i <= r.count {
      var diagonal = row[0]
      row[0] = i
      for j in 1 ... max(h.count, 1) where j <= h.count {
        let above = row[j]
        row[j] = min(row[j] + 1, row[j - 1] + 1, diagonal + (r[i - 1] == h[j - 1] ? 0 : 1))
        diagonal = above
      }
    }
    return (row[h.count], max(r.count, 1))
  }
}
