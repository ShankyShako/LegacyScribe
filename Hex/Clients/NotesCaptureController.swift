import AVFoundation
import CoreAudio
import Foundation
import HexCore

/// Microphone capture for a notes session, separate from dictation's `RecordingClient`. Audio is converted
/// to 16 kHz mono, cut by `NotesChunker`, and each chunk lands in `pending/` as a 16-bit WAV: written as
/// `<index>.wav.partial`, synced, then renamed, so the transcribe loop never sees half a chunk.
/// At most ~30 s of audio is ever held in memory.
final class NotesCaptureController: @unchecked Sendable {
	private let folder: NotesSessionFolder
	private let deviceUID: String?
	private let voiceIsolation: Bool
	private let onChunk: @Sendable (Int) -> Void
	private let onMeter: @Sendable (Meter) -> Void
	private let onFailure: @Sendable (String) -> Void
	private let logger = HexLog.notes
	private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

	/// Everything below is touched only on `queue`.
	private let queue = DispatchQueue(label: "com.genovamongalo.LegacyScribe.NotesCapture")
	private var engine: AVAudioEngine?
	private var converter: AVAudioConverter?
	private var observer: NSObjectProtocol?
	/// Bumped whenever the engine is torn down, so callbacks from an old engine are dropped.
	private var generation = 0
	private var chunker = NotesChunker()
	private var nextIndex: Int
	/// Chunks that couldn't be written (disk full, say); retried before each later chunk.
	private var unwritten: [(index: Int, samples: [Float])] = []
	private var stopped = false

	init(
		folder: NotesSessionFolder,
		firstIndex: Int = 0,
		deviceUID: String?,
		voiceIsolation: Bool = false,
		onChunk: @escaping @Sendable (Int) -> Void,
		onMeter: @escaping @Sendable (Meter) -> Void,
		onFailure: @escaping @Sendable (String) -> Void
	) {
		self.folder = folder
		self.nextIndex = firstIndex
		self.deviceUID = deviceUID
		self.voiceIsolation = voiceIsolation
		self.onChunk = onChunk
		self.onMeter = onMeter
		self.onFailure = onFailure
	}

	func start() throws {
		try queue.sync { try armEngine(reason: "start") }
	}

	/// Stops the microphone and writes whatever audio is still buffered as the last chunk.
	/// Returns the number of chunks written in total.
	@discardableResult
	func stop() -> Int {
		queue.sync {
			stopped = true
			detachEngine()
			if let tail = chunker.finish() {
				emit(tail)
			}
			flushUnwritten()
			if !unwritten.isEmpty {
				logger.error("Notes capture stopped with \(self.unwritten.count) chunks unwritten")
				onFailure("\(unwritten.count) audio chunks could not be saved")
			}
			return nextIndex
		}
	}

	// MARK: - Engine

	private func armEngine(reason: String) throws {
		let engine = AVAudioEngine()
		let inputNode = engine.inputNode
		// Before choosing the device: turning voice processing on swaps the input unit.
		if voiceIsolation {
			VoiceIsolation.enable(on: engine)
		}
		if let deviceID = Self.deviceID(uid: deviceUID), let unit = inputNode.audioUnit {
			var device = deviceID
			let status = AudioUnitSetProperty(
				unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
				&device, UInt32(MemoryLayout<AudioDeviceID>.size)
			)
			if status != noErr {
				logger.error("Notes capture couldn't select input \(deviceID): \(status); using the default")
			}
		}
		let inputFormat = inputNode.inputFormat(forBus: 0)
		guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
			throw NotesCaptureError.noInput
		}
		if inputFormat.channelCount > 1 {
			converter.channelMap = [NSNumber(value: 0)]
		}

		generation += 1
		let generation = generation
		self.converter = converter
		inputNode.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
			guard let self, let copy = Self.clone(buffer) else { return }
			queue.async { self.process(copy, generation: generation) }
		}
		engine.prepare()
		do {
			try engine.start()
		} catch {
			inputNode.removeTap(onBus: 0)
			RetiredAudioEngines.retire(engine)
			self.converter = nil
			throw error
		}
		self.engine = engine
		observer = NotificationCenter.default.addObserver(
			forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
		) { [weak self] _ in
			guard let self else { return }
			queue.async { self.restart(generation: generation) }
		}
		logger.notice("Notes capture armed reason=\(reason, privacy: .public) input=\(inputFormat.sampleRate, format: .fixed(precision: 0)) Hz × \(inputFormat.channelCount)")
	}

	private func detachEngine() {
		generation += 1
		if let observer {
			NotificationCenter.default.removeObserver(observer)
			self.observer = nil
		}
		if let engine {
			engine.inputNode.removeTap(onBus: 0)
			engine.stop()
			RetiredAudioEngines.retire(engine)
		}
		engine = nil
		converter = nil
	}

	/// A device change (headphones plugged in, the selected mic unplugged) stops the engine.
	/// Rebuild it; the chunker and the chunk index carry on, so the session just continues.
	private func restart(generation: Int, attempt: Int = 1) {
		guard !stopped, generation == self.generation else { return }
		detachEngine()
		do {
			try armEngine(reason: "configuration-change")
		} catch {
			logger.error("Notes capture restart \(attempt) failed: \(error.localizedDescription, privacy: .public)")
			guard attempt < 5 else {
				onFailure("The microphone stopped: \(error.localizedDescription)")
				return
			}
			let next = self.generation
			queue.asyncAfter(deadline: .now() + 1) { self.restart(generation: next, attempt: attempt + 1) }
		}
	}

	// MARK: - Audio

	#if DEBUG
	/// 16 kHz mono samples from somewhere other than the microphone (the notes harness feeds a file).
	func ingest(_ samples: [Float]) {
		queue.sync {
			guard !stopped else { return }
			for chunk in chunker.append(samples) {
				emit(chunk)
			}
		}
	}
	#endif

	private func process(_ buffer: AVAudioPCMBuffer, generation: Int) {
		guard generation == self.generation, !stopped,
		      let converted = convert(buffer), let channel = converted.floatChannelData?[0]
		else { return }
		let samples = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
		onMeter(Self.meter(samples))
		for chunk in chunker.append(samples) {
			emit(chunk)
		}
	}

	private func emit(_ samples: [Float]) {
		let index = nextIndex
		nextIndex += 1
		flushUnwritten()
		if !write(samples, index: index) {
			unwritten.append((index, samples))
			onFailure("Couldn't save audio; retrying")
		}
	}

	private func flushUnwritten() {
		while let first = unwritten.first, write(first.samples, index: first.index) {
			unwritten.removeFirst()
		}
	}

	private func write(_ samples: [Float], index: Int) -> Bool {
		let destination = folder.pendingChunkURL(index)
		let partial = destination.appendingPathExtension("partial")
		do {
			let fm = FileManager.default
			fm.removeItemIfExists(at: partial)
			guard fm.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
			let handle = try FileHandle(forWritingTo: partial)
			defer { try? handle.close() }
			try handle.write(contentsOf: PCM16WAV.data(samples: samples))
			try handle.synchronize()
			guard rename(partial.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
			onChunk(index)
			return true
		} catch {
			logger.error("Notes chunk \(index) not written: \(error.localizedDescription, privacy: .public)")
			return false
		}
	}

	private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
		guard let converter else { return nil }
		let capacity = AVAudioFrameCount((Double(input.frameLength) * targetFormat.sampleRate / input.format.sampleRate).rounded(.up) + 32)
		guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
		var consumed = false
		var error: NSError?
		let status = converter.convert(to: output, error: &error) { _, outStatus in
			if consumed {
				outStatus.pointee = .noDataNow
				return nil
			}
			consumed = true
			outStatus.pointee = .haveData
			return input
		}
		if let error {
			logger.error("Notes capture conversion failed: \(error.localizedDescription, privacy: .public)")
			return nil
		}
		guard status != .error, output.frameLength > 0 else { return nil }
		return output
	}

	private static func meter(_ samples: [Float]) -> Meter {
		guard !samples.isEmpty else { return Meter(averagePower: 0, peakPower: 0) }
		var sum: Float = 0
		var peak: Float = 0
		for sample in samples {
			sum += sample * sample
			peak = max(peak, abs(sample))
		}
		return Meter(averagePower: Double((sum / Float(samples.count)).squareRoot()), peakPower: Double(peak))
	}

	private static func clone(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
		guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
		copy.frameLength = buffer.frameLength
		let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
		let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
		for index in source.indices {
			guard let from = source[index].mData, let to = destination[index].mData else { continue }
			memcpy(to, from, Int(source[index].mDataByteSize))
			destination[index].mDataByteSize = source[index].mDataByteSize
		}
		return copy
	}

	/// The input chosen in Settings (a device UID, or a numeric ID from older settings); nil means the system default.
	static func deviceID(uid: String?) -> AudioDeviceID? {
		guard let uid else { return nil }
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDeviceForUID,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)
		var cfUID = uid as CFString
		var deviceID = AudioDeviceID(0)
		var size = UInt32(MemoryLayout<AudioDeviceID>.size)
		let status = withUnsafePointer(to: &cfUID) {
			AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &deviceID)
		}
		if status == noErr, deviceID != kAudioObjectUnknown { return deviceID }
		return AudioDeviceID(uid)
	}
}

enum NotesCaptureError: Error, LocalizedError {
	case noInput

	var errorDescription: String? {
		switch self {
		case .noInput: "No microphone input is available"
		}
	}
}
