import Foundation
import Testing

@testable import HexCore

struct FeedbackReportTests {
	private let diagnostics = FeedbackReport.diagnostics(
		appVersion: "0.8.5", build: "42", macOS: "Version 26.0 (Build 25A1)",
		macModel: "Mac17,1", memoryGB: 32, engine: "cohere-transcribe-03-2026-mlx-4bit"
	)

	private func items(_ url: URL) -> [String: String] {
		let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
		return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
	}

	@Test func diagnosticsAreOnePlainFactPerLine() {
		#expect(diagnostics.split(separator: "\n").map(String.init) == [
			"LegacyScribe 0.8.5 (42)",
			"macOS Version 26.0 (Build 25A1)",
			"Mac: Mac17,1, 32 GB memory",
			"Speech engine: cohere-transcribe-03-2026-mlx-4bit",
		])
	}

	@Test func problemURLPointsAtTheIssueFormWithTheBugLabel() {
		let url = FeedbackReport.issueURL(kind: .problem, diagnostics: diagnostics)
		#expect(url.host == "github.com")
		#expect(url.path == "/ShankyShako/LegacyScribe/issues/new")
		#expect(items(url)["labels"] == "bug")
		#expect(items(url)["title"] == "")
	}

	@Test func ideaURLUsesTheEnhancementLabel() {
		let url = FeedbackReport.issueURL(kind: .idea, diagnostics: diagnostics)
		#expect(items(url)["labels"] == "enhancement")
		#expect(items(url)["body"]?.hasPrefix("**Idea**\n\n\n**Why it would help**\n\n\n---\n") == true)
	}

	@Test func bodyIsTheTemplateThenTheDiagnostics() {
		let url = FeedbackReport.issueURL(kind: .problem, diagnostics: diagnostics)
		#expect(items(url)["body"] == "**What happened**\n\n\n**What you expected**\n\n\n---\n" + diagnostics)
	}

	@Test func encodingRoundTripsOddCharacters() {
		let odd = "A & B + C = 100% #1; \"quoted\" ünï"
		let url = FeedbackReport.issueURL(kind: .problem, diagnostics: odd)
		#expect(items(url)["body"]?.hasSuffix(odd) == true)
		#expect(url.absoluteString.contains("&B") == false)
	}

	@Test func newlinesArePercentEncodedNotLiteral() {
		let url = FeedbackReport.issueURL(kind: .idea, diagnostics: diagnostics)
		#expect(url.absoluteString.contains("\n") == false)
		#expect(url.absoluteString.contains("%0A"))
		#expect(items(url)["body"]?.contains("\n\n\n") == true)
	}
}
