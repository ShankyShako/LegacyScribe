import Foundation

/// Cohere Transcribe checkpoints run in-process with MLX (mlx-audio-swift). English-only here.
/// On the user's voice (2026-10-06) 4-bit had the lowest WER of every engine tried (5.3%) at
/// ~320 ms per 10 s of audio; see docs/bench-results.md. 8-bit was no better and 0.9 GB larger.
public enum CohereModel: String, CaseIterable, Sendable {
	case fourBit = "cohere-transcribe-03-2026-mlx-4bit"

	public var identifier: String { rawValue }

	/// Hugging Face repo holding the MLX conversion.
	public var repository: String { "beshkenadze/\(rawValue)" }

	/// Files `CohereTranscribeModel.fromDirectory` needs.
	public static let requiredFiles = [
		"config.json",
		"preprocessor_config.json",
		"special_tokens_map.json",
		"tokenizer.model",
		"tokenizer_config.json",
		"model.safetensors",
	]
}
