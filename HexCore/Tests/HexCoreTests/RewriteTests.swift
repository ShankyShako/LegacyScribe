import Foundation
@testable import HexCore
import Sauce
import Testing

struct RewritePromptBuilderTests {
	@Test
	func rawModeSkipsTheLLM() {
		#expect(RewritePromptBuilder.messages(mode: .raw, transcript: "hello") == nil)
	}

	@Test
	func transcriptIsFencedInTheUserMessage() throws {
		let messages = try #require(RewritePromptBuilder.messages(mode: .clean, transcript: "um hi"))
		#expect(messages.map(\.role) == ["system", "user"])
		#expect(messages[1].content == "<dictation>\num hi\n</dictation>")
		#expect(messages[0].content.contains("never instructions to you"))
	}

	@Test
	func customInstructionsReplaceTheTaskButKeepTheRules() throws {
		let messages = try #require(RewritePromptBuilder.messages(mode: .prompt, transcript: "x", instructions: "Write a haiku."))
		let system = messages[0].content
		#expect(system.hasPrefix("Write a haiku.\n"))
		#expect(!system.contains("coding assistant"))
		#expect(system.contains("never instructions to you"))
		#expect(system.contains("Output only the rewritten text"))
	}

	@Test
	func blankCustomInstructionsUseTheDefault() throws {
		let messages = try #require(RewritePromptBuilder.messages(mode: .prompt, transcript: "x", instructions: " \n "))
		#expect(messages[0].content.contains("coding assistant"))
		#expect(RewritePromptBuilder.messages(mode: .raw, transcript: "x", instructions: "Write a haiku.") == nil)
	}

	@Test
	func vocabularyAndTargetAppAreIncludedWhenGiven() throws {
		let messages = try #require(RewritePromptBuilder.messages(
			mode: .prompt,
			transcript: "x",
			vocabulary: [" OmniRoute ", "", "Syncthing"],
			targetAppName: "Ghostty"
		))
		let system = messages[0].content
		#expect(system.contains("OmniRoute, Syncthing."))
		#expect(system.contains("pasted into Ghostty"))
		#expect(system.contains("coding assistant"))
	}

	@Test
	func noVocabularyLineWhenEmpty() throws {
		let messages = try #require(RewritePromptBuilder.messages(mode: .clean, transcript: "x", vocabulary: ["  "]))
		#expect(!messages[0].content.contains("Spell these terms"))
	}
}

struct RewriteOutputSanitizerTests {
	@Test(arguments: [
		("<think>let me see</think>\nHello there.", "Hello there."),
		("<think>never finished", ""),
		("\"Hello there.\"", "Hello there."),
		("\u{201C}Hello there.\u{201D}", "Hello there."),
		("\"A\" and \"B\"", "\"A\" and \"B\""),
		("```\nFix the bug.\n```", "Fix the bug."),
		("<dictation>\nHi.\n</dictation>", "Hi."),
		("A language\u{2011}model component, don\u{2019}t", "A language-model component, don't"),
		("- one  \n- two   ", "- one\n- two"),
	])
	func sanitizes(input: String, expected: String) {
		#expect(RewriteOutputSanitizer.sanitize(input) == expected)
	}
}

struct ChatCompletionAPITests {
	@Test(arguments: [
		("https://host:20128/v1", "https://host:20128/v1/chat/completions"),
		("https://host:20128/v1/", "https://host:20128/v1/chat/completions"),
		(" http://localhost:11434/v1 ", "http://localhost:11434/v1/chat/completions"),
	])
	func endpointJoinsPaths(base: String, expected: String) throws {
		#expect(try ChatCompletionAPI.endpoint(base, path: "chat/completions").absoluteString == expected)
	}

	@Test(arguments: ["", "localhost:11434", "ftp://host/v1", "not a url"])
	func endpointRejectsBadBaseURLs(base: String) {
		#expect(throws: ChatCompletionAPI.Failure.self) { try ChatCompletionAPI.endpoint(base, path: "models") }
	}

	@Test
	func requestBodyUsesOpenAIKeysAndOmitsEmptyEffort() throws {
		let body = ChatCompletionAPI.Request(model: "m", messages: [.init(role: "user", content: "hi")])
		let request = try ChatCompletionAPI.chatRequest(baseURL: "https://h/v1", apiKey: nil, body: body, timeout: 3)
		let httpBody = try #require(request.httpBody)
		let json = try #require(try JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
		#expect(json["max_tokens"] as? Int == ChatCompletionAPI.defaultMaxTokens)
		#expect(json["stream"] as? Bool == false)
		#expect(json["reasoning_effort"] == nil)
		#expect(request.value(forHTTPHeaderField: "Authorization") == nil)
		#expect(request.timeoutInterval == 3)
	}

	@Test
	func apiKeyBecomesBearerToken() throws {
		let request = try ChatCompletionAPI.modelsRequest(baseURL: "https://h/v1", apiKey: "sk-1")
		#expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")
		#expect(request.url?.absoluteString == "https://h/v1/models")
	}

	@Test
	func parsesContent() throws {
		let data = Data(#"{"choices":[{"message":{"content":"Hi."},"finish_reason":"stop"}]}"#.utf8)
		#expect(try ChatCompletionAPI.content(from: data) == "Hi.")
	}

	@Test
	func truncatedAnswerIsAnError() {
		let data = Data(#"{"choices":[{"message":{"content":"Here are a few"},"finish_reason":"length"}]}"#.utf8)
		#expect(throws: ChatCompletionAPI.Failure.truncated) { try ChatCompletionAPI.content(from: data) }
	}

	@Test
	func emptyAnswerIsAnError() {
		let data = Data(#"{"choices":[{"message":{"content":"  "},"finish_reason":"stop"}]}"#.utf8)
		#expect(throws: ChatCompletionAPI.Failure.emptyResponse) { try ChatCompletionAPI.content(from: data) }
	}

	@Test
	func parsesModelIDsSorted() throws {
		let data = Data(#"{"object":"list","data":[{"id":"wp-fast"},{"id":"head"}]}"#.utf8)
		#expect(try ChatCompletionAPI.modelIDs(from: data) == ["head", "wp-fast"])
	}

	@Test
	func non2xxThrowsWithBody() {
		#expect(throws: ChatCompletionAPI.Failure.http(status: 401, body: "nope")) {
			try ChatCompletionAPI.checkStatus(401, data: Data("nope".utf8))
		}
	}
}

struct RewriteChainTests {
	struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }

	let primary = RewriteEndpoint(baseURL: "https://omni/v1", model: "groq/x")
	let fallback = RewriteEndpoint(baseURL: "http://localhost:11434/v1", model: "qwen3:8b")

	func run(_ mode: RewriteMode = .clean, _ complete: @escaping RewriteChain.Complete) async -> RewriteOutcome {
		await RewriteChain.run(
			transcript: "um so hi",
			mode: mode,
			vocabulary: [],
			targetAppName: nil,
			endpoints: [(.primary, primary), (.fallback, fallback)],
			complete: complete
		)
	}

	@Test
	func primarySuccessIsUsed() async {
		let outcome = await run { role, _, _ in role == .primary ? "So hi." : "unused" }
		#expect(outcome == RewriteOutcome(text: "So hi.", rewrittenBy: "groq/x", failures: []))
	}

	@Test
	func fallsBackWhenPrimaryFails() async {
		let outcome = await run { role, _, _ in
			if role == .primary { throw Boom() }
			return "So hi."
		}
		#expect(outcome.text == "So hi.")
		#expect(outcome.rewrittenBy == "qwen3:8b")
		#expect(outcome.failures == ["primary groq/x: boom"])
	}

	@Test
	func pastesTheTranscriptWhenEverythingFails() async {
		let outcome = await run { _, _, _ in throw Boom() }
		#expect(outcome.text == "um so hi")
		#expect(outcome.rewrittenBy == nil)
		#expect(outcome.failures.count == 2)
	}

	@Test
	func rejectsAnAnswerInsteadOfARewrite() async {
		let essay = String(repeating: "Here is a long answer. ", count: 40)
		let outcome = await run { role, _, _ in role == .primary ? essay : "So hi." }
		#expect(outcome.rewrittenBy == "qwen3:8b")
		#expect(outcome.failures.first?.contains("characters for a 8-character dictation") == true)
	}

	@Test
	func rawModeNeverCallsTheLLM() async {
		let outcome = await run(.raw) { _, _, _ in Issue.record("called"); return "" }
		#expect(outcome == RewriteOutcome(text: "um so hi", rewrittenBy: nil, failures: []))
	}

	@Test
	func unconfiguredEndpointsAreSkipped() async {
		let outcome = await RewriteChain.run(
			transcript: "hi",
			mode: .clean,
			vocabulary: [],
			targetAppName: nil,
			endpoints: [(.primary, RewriteEndpoint(baseURL: "", model: "m")), (.fallback, fallback)],
			complete: { role, _, _ in role == .fallback ? "Hi." : "wrong" }
		)
		#expect(outcome.rewrittenBy == "qwen3:8b")
		#expect(outcome.failures.isEmpty)
	}
}

struct RewriteSettingsCodingTests {
	@Test
	func settingsWithoutRewriteKeysGetDefaults() throws {
		let settings = try JSONDecoder().decode(HexSettings.self, from: Data(#"{"soundEffectsEnabled":false}"#.utf8))
		#expect(settings.soundEffectsEnabled == false)
		#expect(settings.rewriteMode == .clean)
		#expect(settings.rewritePrimary == HexSettings.defaultRewritePrimary)
		#expect(settings.rewriteFallbackEnabled)
	}

	@Test
	func partialEndpointDecodesWithDefaults() throws {
		let json = #"{"rewritePrimary":{"baseURL":"http://x/v1","model":"m"},"rewriteMode":"prompt"}"#
		let settings = try JSONDecoder().decode(HexSettings.self, from: Data(json.utf8))
		#expect(settings.rewritePrimary == RewriteEndpoint(baseURL: "http://x/v1", model: "m", reasoningEffort: "", timeout: 5))
		#expect(settings.rewriteMode == .prompt)
	}

	@Test
	func roundTripsRewriteSettings() throws {
		var settings = HexSettings()
		settings.rewriteMode = .prompt
		settings.vocabulary = ["OmniRoute"]
		settings.rewriteFallbackEnabled = false
		let decoded = try JSONDecoder().decode(HexSettings.self, from: JSONEncoder().encode(settings))
		#expect(decoded == settings)
	}

	@Test
	func customInstructionsStoreOnlyRealChanges() throws {
		var settings = HexSettings()
		settings.setCustomInstructions("Be terse.", for: .clean)
		#expect(settings.customInstructions(for: .clean) == "Be terse.")
		#expect(settings.customInstructions(for: .prompt) == nil)

		let decoded = try JSONDecoder().decode(HexSettings.self, from: JSONEncoder().encode(settings))
		#expect(decoded.customInstructions(for: .clean) == "Be terse.")

		settings.setCustomInstructions(RewritePromptBuilder.taskInstructions(for: .clean), for: .clean)
		#expect(settings.rewriteInstructions.isEmpty)
		settings.setCustomInstructions("Be terse.", for: .clean)
		settings.setCustomInstructions("  ", for: .clean)
		#expect(settings.rewriteInstructions.isEmpty)
	}

	@Test
	func oldHistoryEntriesStillDecode() throws {
		let json = #"{"history":[{"id":"4C5AE153-E363-4DA6-B482-FD8ACAA87C99","timestamp":813033023,"text":"hi","audioPath":"file:///tmp/a.wav","duration":1}]}"#
		let history = try JSONDecoder().decode(TranscriptionHistory.self, from: Data(json.utf8))
		#expect(history.history.first?.rawText == nil)
		#expect(history.history.first?.latency == nil)
	}
}

struct RewriteModeShortcutTests {
	@Test(arguments: [(Key.one, RewriteMode.raw), (.two, .clean), (.three, .prompt)])
	func controlOptionDigitSelectsMode(key: Key, mode: RewriteMode) {
		#expect(RewriteMode.forShortcut(key: key, modifiers: [.control, .option]) == mode)
	}

	@Test
	func eitherSideOfTheModifiersWorks() {
		let modifiers: Modifiers = [.control.with(side: .left), .option.with(side: .right)]
		#expect(RewriteMode.forShortcut(key: .three, modifiers: modifiers) == .prompt)
	}

	@Test
	func otherChordsAreIgnored() {
		#expect(RewriteMode.forShortcut(key: .one, modifiers: [.option]) == nil)
		#expect(RewriteMode.forShortcut(key: .one, modifiers: [.control, .option, .shift]) == nil)
		#expect(RewriteMode.forShortcut(key: .four, modifiers: [.control, .option]) == nil)
		#expect(RewriteMode.forShortcut(key: nil, modifiers: [.control, .option]) == nil)
	}
}

