import Foundation
@testable import HexCore
import Testing

struct VocabularySuggesterTests {
	@Test
	func parsesTheArrayInsideProseAndFences() throws {
		let answer = """
		Here you go:
		```json
		[{"term": "Tailscale", "heardAs": ["tail scale"], "reason": "Misheard twice."},
		 {"term": "OmniRoute", "reason": "Used often."},
		 {"term": "tailscale", "heardAs": [], "reason": "dup"},
		 {"term": "  ", "heardAs": [], "reason": "blank"},
		 {"term": "Syncthing", "heardAs": ["sync thing"], "reason": "Known"}]
		```
		"""
		let suggestions = try #require(VocabularySuggester.parse(answer, vocabulary: ["syncthing"]))
		#expect(suggestions.map(\.term) == ["Tailscale", "OmniRoute"])
		#expect(suggestions[0].heardAs == ["tail scale"])
		#expect(suggestions[1].heardAs == [])
	}

	@Test
	func emptyArrayAndGarbage() {
		#expect(VocabularySuggester.parse("[]", vocabulary: []) == [])
		#expect(VocabularySuggester.parse("no idea", vocabulary: []) == nil)
	}

	@Test
	func pairsPreferSentEditsAndSkipUnchangedOnes() {
		let history = [
			Transcript(timestamp: .now, text: "Use Tailscale.", audioPath: URL(fileURLWithPath: "/a"), duration: 1, rawText: "use tail scale"),
			Transcript(timestamp: .now, text: "Hello.", audioPath: URL(fileURLWithPath: "/b"), duration: 1, rawText: "hello"),
			Transcript(timestamp: .now, text: "raw only", audioPath: URL(fileURLWithPath: "/c"), duration: 1),
		]
		let edit = SentEdit(
			timestamp: .now, transcriptID: nil, bundleID: nil, appName: nil, mode: .prompt,
			recognized: "fix omni root", pasted: "Fix omni root.", sent: "Fix OmniRoute."
		)
		let pairs = VocabularySuggester.pairs(history: history, sentEdits: [edit])
		#expect(pairs == [
			.init(recognized: "fix omni root", final: "Fix OmniRoute."),
			.init(recognized: "use tail scale", final: "Use Tailscale."),
		])
	}

	@Test
	func knownVocabularyIsListedInThePrompt() {
		let messages = VocabularySuggester.messages(pairs: [.init(recognized: "a", final: "b")], vocabulary: ["Groq"])
		#expect(messages[0].content.contains("(Groq)"))
		#expect(messages[1].content == "<pair>\nheard: a\nused: b\n</pair>")
	}
}

struct ChatCompletionStreamTests {
	@Test
	func parsesStreamLines() {
		#expect(ChatCompletionAPI.streamEvent(fromLine: #"data: {"choices":[{"delta":{"content":"Hi"}}]}"#) == .delta("Hi"))
		#expect(ChatCompletionAPI.streamEvent(fromLine: #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#) == .finished(reason: "stop"))
		#expect(ChatCompletionAPI.streamEvent(fromLine: "data: [DONE]") == .done)
		#expect(ChatCompletionAPI.streamEvent(fromLine: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#) == nil)
		#expect(ChatCompletionAPI.streamEvent(fromLine: ": keep-alive") == nil)
		#expect(ChatCompletionAPI.streamEvent(fromLine: "") == nil)
	}
}
