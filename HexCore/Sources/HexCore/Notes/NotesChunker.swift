import Foundation

/// Cuts a notes session's live audio into chunks Cohere can take in one pass. It holds at most
/// `maxSeconds` of samples: once that much has arrived, it cuts at the quietest point between
/// `minSeconds` and `maxSeconds` and keeps the rest for the next chunk, so a word is never split.
public struct NotesChunker: Sendable {
	public static let sampleRate = 16_000
	/// Cohere was trained on clips up to 35 s; `CohereClient` cuts dictations the same way.
	public static let minSeconds = 20
	public static let maxSeconds = 30
	/// Loudness is compared over windows this long.
	static let frameSamples = sampleRate / 10

	private(set) var buffer: [Float] = []

	public init() {
		buffer.reserveCapacity(Self.maxSeconds * Self.sampleRate)
	}

	public var bufferedSeconds: Double { Double(buffer.count) / Double(Self.sampleRate) }

	/// Adds samples (16 kHz mono) and returns every chunk completed by them, oldest first.
	public mutating func append(_ samples: [Float]) -> [[Float]] {
		var chunks: [[Float]] = []
		var rest = samples[...]
		let limit = Self.maxSeconds * Self.sampleRate
		while !rest.isEmpty {
			let take = min(rest.count, limit - buffer.count)
			buffer.append(contentsOf: rest.prefix(take))
			rest = rest.dropFirst(take)
			if buffer.count >= limit {
				let cut = Self.quietestCut(in: buffer)
				chunks.append(Array(buffer[..<cut]))
				buffer.removeSubrange(..<cut)
			}
		}
		return chunks
	}

	/// The samples not yet cut into a chunk; empties the buffer. Nil when nothing is left.
	public mutating func finish() -> [Float]? {
		defer { buffer.removeAll(keepingCapacity: false) }
		return buffer.isEmpty ? nil : buffer
	}

	/// Sample index at the centre of the quietest window between `minSeconds` and `maxSeconds`;
	/// the earliest one wins a tie.
	static func quietestCut(in samples: [Float]) -> Int {
		let start = minSeconds * sampleRate
		let end = min(samples.count, maxSeconds * sampleRate)
		guard end - start >= frameSamples else { return min(samples.count, end) }
		var best = start
		var bestEnergy = Float.infinity
		var frame = start
		while frame + frameSamples <= end {
			var energy: Float = 0
			for index in frame ..< frame + frameSamples {
				energy += samples[index] * samples[index]
			}
			if energy < bestEnergy {
				bestEnergy = energy
				best = frame
			}
			frame += frameSamples
		}
		return best + frameSamples / 2
	}

	/// True when no 100 ms window rises above a quiet room, so the chunk needs no transcription.
	public static func isSilent(_ samples: [Float], threshold: Float = 0.003) -> Bool {
		var frame = 0
		while frame < samples.count {
			let slice = samples[frame ..< min(samples.count, frame + frameSamples)]
			let rms = (slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)).squareRoot()
			if rms > threshold { return false }
			frame += frameSamples
		}
		return true
	}
}

/// 16-bit PCM WAV encoding for notes chunks (~0.8 MB per 25 s at 16 kHz mono).
public enum PCM16WAV {
	public static func data(samples: [Float], sampleRate: Int = NotesChunker.sampleRate) -> Data {
		let dataBytes = samples.count * 2
		var data = Data(capacity: 44 + dataBytes)
		func append<T: FixedWidthInteger>(_ value: T) {
			withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
		}
		data.append(contentsOf: Array("RIFF".utf8))
		append(UInt32(36 + dataBytes))
		data.append(contentsOf: Array("WAVEfmt ".utf8))
		append(UInt32(16)) // fmt chunk size
		append(UInt16(1)) // PCM
		append(UInt16(1)) // mono
		append(UInt32(sampleRate))
		append(UInt32(sampleRate * 2)) // byte rate
		append(UInt16(2)) // block align
		append(UInt16(16)) // bits per sample
		data.append(contentsOf: Array("data".utf8))
		append(UInt32(dataBytes))
		let pcm = samples.map { Int16((max(-1, min(1, $0)) * Float(Int16.max)).rounded()).littleEndian }
		pcm.withUnsafeBytes { data.append(contentsOf: $0) }
		return data
	}

	/// Samples of a WAV written by `data(samples:)`; nil for anything else or a truncated file.
	public static func samples(from data: Data) -> [Float]? {
		guard data.count >= 44,
		      data.prefix(4).elementsEqual("RIFF".utf8),
		      data[data.startIndex + 36 ..< data.startIndex + 40].elementsEqual("data".utf8)
		else { return nil }
		let declared = data[data.startIndex + 40 ..< data.startIndex + 44].withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
		let body = data.dropFirst(44)
		guard body.count == Int(declared), body.count % 2 == 0 else { return nil }
		return body.withUnsafeBytes { raw in
			(0 ..< body.count / 2).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / Float(Int16.max) }
		}
	}
}
