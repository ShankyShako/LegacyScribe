import Foundation

/// The Practice tab's research question: what's known about personalizing speech and text models from a
/// person's own transcriptions, asked of a search-capable model through OmniRoute.
public enum PracticeResearch {
	public struct Context: Equatable, Sendable {
		public var dictations: Int
		public var sentEdits: Int
		public var editedSentEdits: Int
		public var engine: String

		public init(dictations: Int, sentEdits: Int, editedSentEdits: Int, engine: String) {
			self.dictations = dictations
			self.sentEdits = sentEdits
			self.editedSentEdits = editedSentEdits
			self.engine = engine
		}
	}

	public static func messages(_ context: Context) -> [ChatMessage] {
		let system = """
		You are a research assistant. Search for current papers, model cards, repositories and benchmarks, and \
		answer in Markdown with a link for every claim. Say which findings are established and which are \
		speculative or anecdotal. Be concrete: model names, data amounts, hardware, results.
		"""
		let question = """
		I use a local macOS dictation app on an Apple Silicon Mac (M5, 24 GB). Speech-to-text runs on-device; \
		my current engine is \(context.engine). Other engines available: Cohere Transcribe (4-bit MLX), \
		NVIDIA Parakeet TDT v3 (CoreML via FluidAudio), Whisper (WhisperKit) and Apple SpeechAnalyzer. An LLM \
		then cleans up the transcript or turns it into a prompt for a coding assistant.
		So far I have \(context.dictations) dictations with audio and recognized text, and \(context.sentEdits) \
		records of what I actually sent after pasting (\(context.editedSentEdits) of them edited by hand).

		1. Which of these speech models (or close alternatives) capture enough detail from one person's \
		recordings to make personalized training worthwhile: LoRA or fine-tuning on my own audio and \
		corrected transcripts? How many hours or utterances do published results need, and what word error \
		rate gains do they report?
		2. Which can realistically be fine-tuned on Apple Silicon (MLX, PyTorch MPS) and loaded back into a \
		Swift app?
		3. For the text side: what works for learning a person's vocabulary and style from their edits \
		(few-shot examples from history, retrieval, preference tuning, small-model LoRA)?
		4. What would you do first with the data I have, and what should I start collecting now?
		"""
		return [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: question)]
	}
}
