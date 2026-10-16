import Foundation

/// Where Cohere Transcribe's input is cut. Cohere was trained on clips up to 35 s and loops on longer ones,
/// so audio over `singlePassSeconds` is cut into even pieces of at most `targetSeconds`, each cut at the
/// quietest 0.1 s within `searchSeconds` of its mark. mlx-audio's own splitter cut at the quietest point
/// within ±5 s of every 25 s mark, which for a 25–30 s dictation was often the silence after the last word:
/// the sliver left over came back as "Thank you." (bench-results, "Cohere's trailing thank you").
public enum CohereChunks {
	public static let singlePassSeconds = 30.0
	public static let targetSeconds = 24.0
	public static let searchSeconds = 3.0
	static let windowSeconds = 0.1
	static let stepSeconds = 0.01

	/// Consecutive sample ranges covering `samples`; one range when it fits a single pass. Pieces are at
	/// most `targetSeconds` + 2 × `searchSeconds` (30 s) and, past a single pass, at least 9 s.
	public static func ranges(_ samples: [Float], sampleRate: Int) -> [Range<Int>] {
		let rate = Double(sampleRate)
		guard Double(samples.count) > singlePassSeconds * rate else { return [0 ..< samples.count] }
		let pieces = Int((Double(samples.count) / (targetSeconds * rate)).rounded(.up))
		let step = max(1, Int(stepSeconds * rate))
		let window = max(1, Int(windowSeconds * rate) / step)
		// Energy of each 10 ms step, summed over a sliding 0.1 s window when searching.
		let energy: [Float] = (0 ..< samples.count / step).map { index in
			var sum: Float = 0
			for sample in samples[index * step ..< (index + 1) * step] { sum += sample * sample }
			return sum
		}
		var cuts: [Int] = []
		for piece in 1 ..< pieces {
			let mark = Double(samples.count) * Double(piece) / Double(pieces) / Double(step)
			let low = max(0, Int(mark - searchSeconds * rate / Double(step)))
			let high = min(energy.count - window, Int(mark + searchSeconds * rate / Double(step)))
			guard high > low else {
				cuts.append(Int(mark) * step)
				continue
			}
			var sum = energy[low ..< low + window].reduce(0, +)
			var best = (start: low, sum: sum)
			for start in low + 1 ... high {
				sum += energy[start + window - 1] - energy[start - 1]
				if sum < best.sum { best = (start, sum) }
			}
			cuts.append((best.start + window / 2) * step)
		}
		let bounds = [0] + cuts + [samples.count]
		return zip(bounds, bounds.dropFirst()).map { $0 ..< $1 }
	}
}
