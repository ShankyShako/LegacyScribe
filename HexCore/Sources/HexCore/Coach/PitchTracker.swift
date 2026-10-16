import Foundation

/// How much the voice's pitch moves, for the filler-free minute (talking as to a person; dictation to a
/// computer is flatter by nature, so it isn't measured there). Autocorrelation pitch on 40 ms frames of
/// the audio taken down to 8 kHz.
public enum PitchTracker {
	static let rate = 8000.0
	static let frameSeconds = 0.04
	static let hopSeconds = 0.02
	/// Speaking voices sit between about 75 Hz (low male) and 400 Hz (high female, raised).
	static let lowestHz = 75.0
	static let highestHz = 400.0
	/// A frame counts as voiced when it repeats this well at its best lag.
	static let voicing: Float = 0.5
	static let minimumVoicedFrames = 50

	/// The spread of the voiced pitch in semitones, from its 10th to its 90th percentile (the extremes are
	/// mostly octave errors and creaks). Nil when there's too little voiced speech.
	public static func semitoneRange(samples: [Float], sampleRate: Double) -> Double? {
		let all = self.pitches(samples: samples, sampleRate: sampleRate).sorted()
		guard all.count >= minimumVoicedFrames else { return nil }
		// Frames read an octave off (a doubled period, a creak) land far from the voice's middle; a real
		// sentence rarely strays more than ~11 semitones from it.
		let middle = all[all.count / 2]
		let pitches = all.filter { $0 > middle / 1.9 && $0 < middle * 1.9 }
		guard pitches.count >= minimumVoicedFrames else { return nil }
		let low = pitches[pitches.count / 10], high = pitches[pitches.count * 9 / 10]
		return 12 * log2(high / low)
	}

	/// Hz of each voiced frame.
	static func pitches(samples: [Float], sampleRate: Double) -> [Double] {
		let audio = downsample(samples, from: sampleRate)
		let frame = Int(rate * frameSeconds), hop = Int(rate * hopSeconds)
		let minLag = Int(rate / highestHz), maxLag = Int(rate / lowestHz)
		guard audio.count > frame + maxLag + 1 else { return [] }

		// Quiet frames are skipped before the costly part, against the loud end of the recording.
		var energies: [Float] = []
		for start in stride(from: 0, to: audio.count - frame - maxLag - 1, by: hop) {
			var sum: Float = 0
			for i in start ..< start + frame { sum += audio[i] * audio[i] }
			energies.append(sum / Float(frame))
		}
		guard let loud = energies.sorted().dropLast(energies.count / 20).last, loud > 0 else { return [] }
		let gate = loud * 0.02

		var pitches: [Double] = []
		audio.withUnsafeBufferPointer { a in
			for (n, energy) in energies.enumerated() where energy >= gate {
				let start = n * hop
				var correlations = [Float](repeating: 0, count: maxLag + 2)
				for lag in minLag ... maxLag + 1 {
					var dot: Float = 0, e1: Float = 0, e2: Float = 0
					for i in start ..< start + frame {
						let x = a[i], y = a[i + lag]
						dot += x * y
						e1 += x * x
						e2 += y * y
					}
					correlations[lag] = dot / max((e1 * e2).squareRoot(), .leastNonzeroMagnitude)
				}
				let best = correlations[minLag ... maxLag].max() ?? 0
				guard best >= voicing else { continue }
				// The first peak close to the best one: a period's multiples correlate almost as well, and
				// taking the highest would often report the pitch an octave low.
				guard let lag = (minLag + 1 ..< maxLag).first(where: {
					correlations[$0] >= best * 0.9 && correlations[$0] >= correlations[$0 - 1] && correlations[$0] >= correlations[$0 + 1]
				}) else { continue }
				// Parabolic interpolation between lags: at 8 kHz one lag step is about 2% of the pitch at 180 Hz.
				let (l, c, r) = (correlations[lag - 1], correlations[lag], correlations[lag + 1])
				let denominator = l - 2 * c + r
				let shift = denominator == 0 ? 0 : Double(0.5 * (l - r) / denominator)
				pitches.append(rate / (Double(lag) + shift))
			}
		}
		return pitches
	}

	/// Averaging decimation; good enough for pitch, which sits far below 4 kHz.
	static func downsample(_ samples: [Float], from sampleRate: Double) -> [Float] {
		let step = max(1, Int((sampleRate / rate).rounded()))
		guard step > 1 else { return samples }
		var out: [Float] = []
		out.reserveCapacity(samples.count / step)
		var i = 0
		while i + step <= samples.count {
			var sum: Float = 0
			for j in i ..< i + step { sum += samples[j] }
			out.append(sum / Float(step))
			i += step
		}
		return out
	}
}
