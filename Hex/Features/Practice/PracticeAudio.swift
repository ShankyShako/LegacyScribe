import AVFoundation
import Foundation
import HexCore

/// File work for practice recordings: trimming on save, measuring the folder, deleting trained audio.
enum PracticeAudio {
	/// Writes the spoken part of `source` to `destination` as 16-bit PCM (half the size of the recorder's
	/// 32-bit float, the same to a speech model) and deletes `source`. Returns the kept seconds. If
	/// anything goes wrong the file is moved over untouched, so a recording is never lost.
	static func saveTrimmed(from source: URL, to destination: URL) throws -> TimeInterval? {
		let fileManager = FileManager.default
		fileManager.removeItemIfExists(at: destination)
		do {
			let input = try AVAudioFile(forReading: source)
			let format = input.processingFormat
			guard input.length > 0,
			      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.length))
			else { throw CocoaError(.fileReadCorruptFile) }
			try input.read(into: buffer)
			guard let channels = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }

			let first = Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
			let range = SilenceTrim.speechRange(samples: first, sampleRate: format.sampleRate)
			guard let kept = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count))
			else { throw CocoaError(.fileWriteUnknown) }
			kept.frameLength = AVAudioFrameCount(range.count)
			for channel in 0 ..< Int(format.channelCount) {
				kept.floatChannelData![channel].update(from: channels[channel] + range.lowerBound, count: range.count)
			}

			let output = try AVAudioFile(
				forWriting: destination,
				settings: [
					AVFormatIDKey: Int(kAudioFormatLinearPCM),
					AVSampleRateKey: format.sampleRate,
					AVNumberOfChannelsKey: format.channelCount,
					AVLinearPCMBitDepthKey: 16,
					AVLinearPCMIsFloatKey: false,
					AVLinearPCMIsBigEndianKey: false,
				],
				commonFormat: .pcmFormatFloat32,
				interleaved: false
			)
			try output.write(from: kept)
			output.close()
			try fileManager.removeItem(at: source)
			let seconds = Double(range.count) / format.sampleRate
			HexLog.learning.info("Practice line trimmed to \(seconds, format: .fixed(precision: 2)) s of \(Double(first.count) / format.sampleRate, format: .fixed(precision: 2)) s")
			return seconds
		} catch {
			HexLog.learning.error("Practice trim failed, keeping the recording as is: \(error.localizedDescription, privacy: .public)")
			fileManager.removeItemIfExists(at: destination)
			try fileManager.moveItem(at: source, to: destination)
			return nil
		}
	}

	/// File name → size for everything in the folder; empty if it doesn't exist yet, nil if it can't be read.
	static func scan(_ folder: URL) -> [String: Int64]? {
		let fileManager = FileManager.default
		guard fileManager.fileExists(atPath: folder.path) else { return [:] }
		guard let urls = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else {
			return nil
		}
		var sizes: [String: Int64] = [:]
		for url in urls {
			sizes[url.lastPathComponent] = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
		}
		return sizes
	}

	/// Deletes the audio and reference text of these recordings.
	static func delete(_ recordings: [PracticeRecording], in folder: URL) {
		for recording in recordings {
			FileManager.default.removeItemIfExists(at: folder.appending(component: recording.audioFileName))
			FileManager.default.removeItemIfExists(at: folder.appending(component: "\(recording.lineID).txt"))
		}
	}
}
