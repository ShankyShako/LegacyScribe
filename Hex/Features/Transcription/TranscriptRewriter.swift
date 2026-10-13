import ComposableArchitecture
import Foundation
import HexCore

/// The steps between the engine's text and the text that's pasted: word removals and remappings, then the
/// rewrite chain. The dictation pipeline runs them with the focused field around them (code talk, merge);
/// History's Retry runs them on a recording again with `redo`.
struct TranscriptRewriter {
  @Dependency(\.rewrite) var rewrite
  @Dependency(\.localLLM) var localLLM
  @Dependency(\.keychain) var keychain

  struct Redo: Equatable, Sendable {
    /// What a paste would be: rewritten (when the rewrite worked) and formatted.
    var text: String
    /// The engine's words when `text` was rewritten; nil otherwise, like `Transcript.rawText`.
    var rawText: String?
    var outcome: RewriteOutcome?
    var rewriteMode: RewriteMode?
  }

  /// Runs a recognized transcript through the current settings without a focused field: no code talk, no
  /// merge and no nearby names. The on-device model is unloaded afterwards, as after a dictation.
  func redo(_ recognized: String, mode: RewriteMode, settings: HexSettings, biasing: BiasingContext, targetAppName: String?) async -> Redo {
    var output = applyWordModifications(recognized, settings: settings)
    var outcome: RewriteOutcome?
    var applied: RewriteMode?
    if mode.rewrites, !output.isEmpty {
      let result = await rewrite(output, mode: mode, settings: settings, biasing: biasing, targetAppName: targetAppName)
      outcome = result
      if result.rewrittenBy != nil {
        output = result.text
        applied = mode
      }
      if settings.rewritePrimary.provider == .onDevice
        || (settings.rewriteFallbackEnabled && settings.rewriteFallback.provider == .onDevice) {
        await localLLM.unload()
      }
    }
    output = TranscriptFormattingApplier.apply(
      output,
      lowercase: settings.lowercaseTranscripts,
      removePunctuation: settings.removePunctuation
    )
    return Redo(text: output, rawText: applied == nil ? nil : recognized, outcome: outcome, rewriteMode: applied)
  }

  /// Word removals then remappings, as configured in Settings.
  func applyWordModifications(_ text: String, settings: HexSettings) -> String {
    var output = text
    if settings.wordRemovalsEnabled {
      let removedResult = WordRemovalApplier.apply(output, removals: settings.wordRemovals)
      if removedResult != output {
        let enabledRemovalCount = settings.wordRemovals.filter(\.isEnabled).count
        HexLog.transcription.info("Applied \(enabledRemovalCount) word removal(s)")
      }
      output = removedResult
    }
    let remappedResult = WordRemappingApplier.apply(output, remappings: settings.wordRemappings)
    if remappedResult != output {
      HexLog.transcription.info("Applied \(settings.wordRemappings.count) word remapping(s)")
    }
    return remappedResult
  }

  /// Primary endpoint, then the fallback; returns the transcript unchanged if both fail,
  /// so a network problem never costs the dictation.
  func rewrite(
    _ transcript: String,
    mode: RewriteMode,
    settings: HexSettings,
    biasing: BiasingContext,
    targetAppName: String?,
    codeTalkCommands: [String]? = nil,
    existingText: String? = nil
  ) async -> RewriteOutcome {
    let endpoints = usableEndpoints(settings)
    guard !endpoints.isEmpty else {
      return RewriteOutcome(text: transcript, rewrittenBy: nil, failures: [])
    }
    let outcome = await RewriteChain.run(
      transcript: transcript,
      mode: mode,
      vocabulary: biasing.exactTerms,
      nearbyTerms: biasing.nearbyOnly,
      targetAppName: targetAppName,
      instructions: settings.customInstructions(for: mode),
      codeTalkCommands: codeTalkCommands,
      existingText: existingText,
      endpoints: endpoints,
      complete: complete
    )
    for failure in outcome.failures {
      HexLog.rewrite.error("Rewrite failed: \(failure, privacy: .public)")
    }
    if let model = outcome.rewrittenBy {
      HexLog.rewrite.info("Rewrote with \(model, privacy: .public) (\(mode.rawValue, privacy: .public))")
    } else {
      HexLog.rewrite.notice("Every rewrite endpoint failed; pasting the transcript as recognized")
    }
    return outcome
  }

  /// A Super dictation: `instruction` applied to the selection or written at the cursor, on the same
  /// endpoints as the rewrite. The outcome's `rewrittenBy` is nil when nothing usable came back (no AI set
  /// up, or every endpoint failed); `failures` is empty only in the first case.
  func superRewrite(
    _ instruction: String,
    request: SuperRequest,
    settings: HexSettings,
    biasing: BiasingContext,
    targetAppName: String?
  ) async -> RewriteOutcome {
    let endpoints = usableEndpoints(settings)
    guard !endpoints.isEmpty else {
      return RewriteOutcome(text: instruction, rewrittenBy: nil, failures: [])
    }
    let messages = SuperPrompt.messages(
      instruction: instruction,
      request: request,
      vocabulary: biasing.exactTerms,
      nearbyTerms: biasing.nearbyOnly,
      targetAppName: targetAppName
    )
    let outcome = await RewriteChain.run(messages: messages, original: instruction, endpoints: endpoints, complete: complete) {
      SuperPrompt.rejection(of: $0, instruction: instruction, request: request)
    }
    for failure in outcome.failures {
      HexLog.rewrite.error("Super failed: \(failure, privacy: .public)")
    }
    if let model = outcome.rewrittenBy {
      HexLog.rewrite.info("Super answered by \(model, privacy: .public)")
    }
    return outcome
  }

  private var complete: RewriteChain.Complete {
    { [rewrite, keychain] role, endpoint, messages in
      try await rewrite.complete(endpoint, keychain.read(endpoint.keychainAccount(role)), messages)
    }
  }

  /// The endpoints to try, in order: the primary, then the fallback when it's on.
  private func usableEndpoints(_ settings: HexSettings) -> [(RewriteEndpointRole, RewriteEndpoint)] {
    var endpoints: [(RewriteEndpointRole, RewriteEndpoint)] = [(.primary, settings.rewritePrimary)]
    if settings.rewriteFallbackEnabled {
      endpoints.append((.fallback, settings.rewriteFallback))
    }
    // Private mode runs only the in-process model; a cloud or localhost endpoint is skipped, not failed.
    if settings.privateMode {
      endpoints = endpoints.filter { NetworkPolicy.allows($0.1, privateMode: true) }
      if endpoints.isEmpty {
        HexLog.rewrite.notice("Private mode and no on-device rewrite model; pasting the transcript as recognized")
      }
    }
    // A model not downloaded yet or a key not pasted yet isn't a failure: the AI just isn't set up, so the
    // transcript is pasted without the "rewrite failed" notice.
    endpoints = endpoints.filter { role, endpoint in
      switch endpoint.provider {
      case .onDevice:
        return LocalLLMModel(rawValue: endpoint.model).map(localLLM.isDownloaded) ?? false
      default:
        return !endpoint.provider.needsAPIKey || !(keychain.read(endpoint.keychainAccount(role)) ?? "").isEmpty
      }
    }
    if endpoints.isEmpty {
      HexLog.rewrite.notice("No rewrite AI is set up; pasting the transcript as recognized")
    }
    return endpoints
  }
}
