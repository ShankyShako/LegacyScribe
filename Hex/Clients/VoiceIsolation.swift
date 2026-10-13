import AVFoundation
import HexCore

/// Apple's voice processing on an `AVAudioEngine` input: it keeps the voice nearest the microphone and turns
/// down other voices, echo and noise. While it's on, the system's Mic Mode menu applies to LegacyScribe, and
/// its Voice Isolation setting removes background voices more strongly.
enum VoiceIsolation {
  /// Call before reading the input format or starting the engine. Returns false (and leaves the engine as it
  /// was) when the device doesn't support it.
  @discardableResult
  static func enable(on engine: AVAudioEngine) -> Bool {
    let input = engine.inputNode
    do {
      try input.setVoiceProcessingEnabled(true)
    } catch {
      HexLog.recording.error("Voice isolation unavailable: \(error.localizedDescription, privacy: .public)")
      return false
    }
    // Voice processing lowers other audio while the microphone is open; the dictation engine stays open
    // between dictations, so keep music and calls at their normal level.
    input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
    HexLog.recording.notice("Voice isolation on (mic mode \(AVCaptureDevice.activeMicrophoneMode.rawValue))")
    return true
  }

  /// The mic mode the system applies to the app's voice-processed input.
  static var micModeName: String {
    switch AVCaptureDevice.preferredMicrophoneMode {
    case .voiceIsolation: "Voice Isolation"
    case .wideSpectrum: "Wide Spectrum"
    default: "Standard"
    }
  }
}
