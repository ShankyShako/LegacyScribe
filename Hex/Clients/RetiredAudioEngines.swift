import AVFoundation
import Foundation

/// Keeps a stopped `AVAudioEngine` alive for a few seconds before it's released.
///
/// AVFAudio queues the IO unit's property-listener callbacks (`AVAudioIOUnit::IOUnitPropertyListener`) on its
/// own dispatch queue and doesn't cancel them when the engine is deallocated. Releasing an engine right
/// after a device change (a USB headset, AirPods, the iOS Simulator's audio device appearing) let one of
/// those blocks message the freed IO unit: EXC_BAD_ACCESS in `objc_msgSend` on the `AVAudioIOUnit` queue,
/// seen 2026-10-08 and 2026-10-10, ~2 s after "Restarting capture engine … force=true".
enum RetiredAudioEngines {
	/// Long enough for the callbacks a configuration change queues to drain.
	static let holdSeconds: TimeInterval = 10

	private static let lock = NSLock()
	nonisolated(unsafe) private static var engines: [ObjectIdentifier: AVAudioEngine] = [:]

	/// Takes ownership of an engine that has already been stopped and had its taps removed.
	static func retire(_ engine: AVAudioEngine) {
		let id = ObjectIdentifier(engine)
		lock.withLock { engines[id] = engine }
		DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds) {
			// Released on the main queue, away from the audio and capture queues.
			let engine = lock.withLock { engines.removeValue(forKey: id) }
			_ = engine
		}
	}
}
