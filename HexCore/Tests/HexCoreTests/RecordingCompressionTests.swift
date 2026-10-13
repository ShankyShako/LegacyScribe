import AVFoundation
import Foundation
@testable import HexCore
import Testing

struct RecordingCompressionTests {
	/// A float WAV like the capture writes, holding values a 16-bit file can represent exactly.
	func makeWAV(in folder: URL, frames: Int) throws -> (URL, [Float]) {
		let url = folder.appending(component: "1760000000.123.wav")
		let samples = (0 ..< frames).map { Float(Int((sin(Double($0) / 7) * 20000).rounded())) / 32768 }
		let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
		let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
		buffer.frameLength = AVAudioFrameCount(frames)
		for (index, sample) in samples.enumerated() { buffer.floatChannelData![0][index] = sample }
		let file = try AVAudioFile(
			forWriting: url,
			settings: [
				AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
				AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
			],
			commonFormat: .pcmFormatFloat32,
			interleaved: false
		)
		try file.write(from: buffer)
		return (url, samples)
	}

	@Test
	func roundTripIsSampleExactAndSmaller() throws {
		let folder = FileManager.default.temporaryDirectory.appending(component: "flac-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		// Longer than one 65,536-frame read, so the copy loop runs more than once.
		let (wav, samples) = try makeWAV(in: folder, frames: 100_000)

		let flac = try RecordingCompression.flac(from: wav)

		#expect(flac.lastPathComponent == "1760000000.123.flac")
		#expect(FileManager.default.fileExists(atPath: wav.path))
		#expect(!FileManager.default.fileExists(atPath: folder.appending(component: "1760000000.123.partial.flac").path))
		let file = try AVAudioFile(forReading: flac, commonFormat: .pcmFormatFloat32, interleaved: false)
		#expect(file.fileFormat.sampleRate == 16000)
		let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
		try file.read(into: buffer)
		let decoded = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
		#expect(decoded == samples)

		let size = { (url: URL) in try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int }
		#expect(try size(flac) * 2 < size(wav))
	}
}
