import ComposableArchitecture
import Darwin
import Foundation
import HexCore
import XCTest

@testable import Hex

/// A real Private-mode dictation: the transcript goes through the live rewrite client and the downloaded
/// on-device model while the process is watched for network use. The automated form of the plan's
/// `nettop -p <pid>` check. Skipped when the on-device model isn't downloaded.
@MainActor
final class PrivateModeTests: XCTestCase {
  override func setUp() {
    NetworkPolicy.install()
  }

  override func tearDown() {
    NetworkPolicy.setPrivate(false)
  }

  func testPrivateDictationRewritesOnDeviceWithoutTheNetwork() async throws {
    let model = LocalLLMModel.recommended
    try XCTSkipUnless(LocalLLM.isDownloaded(model), "\(model.repository) not downloaded")

    NetworkPolicy.setPrivate(true)
    let blockedBefore = NetworkPolicy.blockedRequests
    let socketsBefore = Self.internetSockets()
    let watcher = SocketWatcher(baseline: socketsBefore)
    let watching = Task.detached { await watcher.watch() }

    let paste = PastedText()
    let history = Shared(value: TranscriptionHistory())
    var state = TranscriptionFeature.State(
      hexSettings: Shared(value: .init(
        rewriteMode: .clean,
        rewritePrimary: .preset(.onDevice),
        // Enabled and keyless, so only Private mode keeps it from being called.
        rewriteFallback: RewriteEndpoint(provider: .ollama, baseURL: "http://localhost:11434/v1", model: "qwen3:8b"),
        rewriteFallbackEnabled: true,
        privateMode: true
      )),
      isRemappingScratchpadFocused: false,
      modelBootstrapState: Shared(value: .init(isModelReady: true)),
      transcriptionHistory: history
    )
    state.sourceAppBundleID = "com.example.chat"
    let store = TestStore(initialState: state) {
      TranscriptionFeature()
    } withDependencies: {
      $0.rewrite = .liveValue
      $0.localLLM = .liveValue
      $0.keychain.read = { _ in nil }
      $0.focusedText.read = { nil }
      $0.transcriptPersistence.save = { text, audioURL, duration, _, _ in
        Transcript(timestamp: Date(), text: text, audioPath: audioURL, duration: duration)
      }
      $0.pasteboard.paste = { text in await paste.set(text) }
      $0.soundEffects.play = { _ in }
    }
    store.exhaustivity = .off

    let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("private-\(UUID().uuidString).wav")
    let spoken = "um so I think we should uh ship it on friday"
    await store.send(.transcriptionResult(spoken, audioURL, 3, DictationTimeline(keyUp: .now)))
    await store.finish(timeout: .seconds(60))

    watching.cancel()
    let opened = await watcher.opened
    let entry = history.wrappedValue.history.first
    let pasted = await paste.text

    XCTAssertEqual(entry?.rewrittenBy, model.repository, "the on-device model should have rewritten it")
    XCTAssertEqual(entry?.rawText, spoken)
    XCTAssertNil(entry?.rewriteFailures)
    XCTAssertNotNil(pasted)
    XCTAssertNotEqual(pasted, spoken)
    XCTAssertEqual(NetworkPolicy.blockedRequests, blockedBefore, "something tried the network")
    XCTAssertTrue(opened.isEmpty, "internet sockets opened during the dictation: \(opened)")
  }

  /// The watcher's detector does see an internet socket, so an empty result above means something.
  func testSocketDetectorSeesAnInternetSocket() {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(fd, 0)
    defer { close(fd) }
    XCTAssertTrue(Self.internetSockets().contains(fd))
  }

  /// File descriptors of this process's IPv4/IPv6 sockets (Unix-domain sockets, used for XPC and logging,
  /// don't count).
  nonisolated static func internetSockets() -> Set<Int32> {
    let pid = getpid()
    let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bytes > 0 else { return [] }
    let stride = MemoryLayout<proc_fdinfo>.stride
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
    let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
    var sockets = Set<Int32>()
    for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
      var info = socket_fdinfo()
      let size = Int32(MemoryLayout<socket_fdinfo>.size)
      guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
      let family = info.psi.soi_family
      if family == AF_INET || family == AF_INET6 { sockets.insert(fd.proc_fd) }
    }
    return sockets
  }
}

/// Samples the process's internet sockets every 10 ms and keeps any that weren't there at the start.
private actor SocketWatcher {
  let baseline: Set<Int32>
  private(set) var opened: Set<Int32> = []

  init(baseline: Set<Int32>) {
    self.baseline = baseline
  }

  func watch() async {
    while !Task.isCancelled {
      opened.formUnion(PrivateModeTests.internetSockets().subtracting(baseline))
      try? await Task.sleep(for: .milliseconds(10))
    }
  }
}

private actor PastedText {
  private(set) var text: String?
  func set(_ text: String) { self.text = text }
}
