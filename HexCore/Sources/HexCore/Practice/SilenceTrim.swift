import Foundation

/// Finds the spoken part of a practice recording, so the silence before and after it (and the click of
/// the key that started it) isn't stored.
public enum SilenceTrim {
	static let frameSeconds = 0.02
	/// Speech starts where at least `minActive` of `window` frames are loud: a lone click doesn't count.
	static let window = 8
	static let minActive = 4

	/// Sample range to keep, with a margin on both sides. The whole recording if no speech is found.
	public static func speechRange(
		samples: [Float],
		sampleRate: Double,
		padBefore: Double = 0.25,
		padAfter: Double = 0.35
	) -> Range<Int> {
		let all = 0 ..< samples.count
		let frameLength = max(1, Int(sampleRate * frameSeconds))
		let frameCount = samples.count / frameLength
		guard frameCount >= window else { return all }

		let levels: [Float] = (0 ..< frameCount).map { frame in
			let slice = samples[frame * frameLength ..< (frame + 1) * frameLength]
			return (slice.reduce(0) { $0 + $1 * $1 } / Float(frameLength)).squareRoot()
		}
		let sorted = levels.sorted()
		let floor = sorted[sorted.count / 10]
		let peak = sorted[sorted.count - 1]
		let threshold = max(floor * 3, peak * 0.03, 0.001)
		let active = levels.map { $0 > threshold }

		func busy(_ range: Range<Int>) -> Bool {
			active[range.clamped(to: 0 ..< frameCount)].filter { $0 }.count >= minActive
		}
		guard let opening = (0 ..< frameCount).first(where: { busy($0 ..< $0 + window) }),
		      let closing = (0 ..< frameCount).last(where: { busy($0 - window + 1 ..< $0 + 1) }),
		      let first = (opening ..< frameCount).first(where: { active[$0] }),
		      let last = (0 ... closing).last(where: { active[$0] })
		else { return all }

		let start = max(0, first * frameLength - Int(padBefore * sampleRate))
		let end = min(samples.count, (last + 1) * frameLength + Int(padAfter * sampleRate))
		return start < end ? start ..< end : all
	}
}
