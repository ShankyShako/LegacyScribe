import AVFoundation
import Foundation

/// Dictation audio is captured as 32-bit float WAV (cheap to write while recording, ~3.8 MB a minute) and
/// kept as 16-bit FLAC (~1 MB a minute): lossless at the bit depth speech models are trained on, so the
/// recordings stay fine-tuning data. Everything that reads them goes through `AVAudioFile`, which reads FLAC.
public enum RecordingCompression {
	public enum Failure: Error, LocalizedError {
		case lengthMismatch(expected: AVAudioFramePosition, written: AVAudioFramePosition)

		public var errorDescription: String? {
			switch self {
			case let .lengthMismatch(expected, written): "FLAC has \(written) frames, the recording \(expected)"
			}
		}
	}

	/// Writes `wav` as FLAC beside it (same name, `.flac`) and returns that URL. The WAV is left in place: the
	/// caller deletes it once nothing points at it. A half-written file never takes the final name.
	public static func flac(from wav: URL) throws -> URL {
		let target = wav.deletingPathExtension().appendingPathExtension("flac")
		let partial = wav.deletingPathExtension().appendingPathExtension("partial.flac")
		let fm = FileManager.default
		try? fm.removeItem(at: partial)

		let input = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
		do {
			let output = try AVAudioFile(
				forWriting: partial,
				settings: [
					AVFormatIDKey: kAudioFormatFLAC,
					AVSampleRateKey: input.fileFormat.sampleRate,
					AVNumberOfChannelsKey: input.fileFormat.channelCount,
					AVLinearPCMBitDepthKey: 16,
				],
				commonFormat: .pcmFormatFloat32,
				interleaved: false
			)
			guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 1 << 16) else {
				throw CocoaError(.fileWriteUnknown)
			}
			while input.framePosition < input.length {
				try input.read(into: buffer)
				guard buffer.frameLength > 0 else { break }
				try output.write(from: buffer)
			}
		} // The output file is closed (and its header finished) when it goes out of scope.

		let written = try AVAudioFile(forReading: partial).length
		guard written == input.length else {
			try? fm.removeItem(at: partial)
			throw Failure.lengthMismatch(expected: input.length, written: written)
		}
		if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
		try fm.moveItem(at: partial, to: target)
		return target
	}
}
