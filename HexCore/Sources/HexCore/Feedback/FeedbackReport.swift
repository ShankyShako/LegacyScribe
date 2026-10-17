import Foundation

/// The text the About tab's "Report a problem", "Suggest a feature" and "Copy diagnostic info" use.
///
/// Pure and deliberately narrow: it takes the app version, the OS, the Mac model, memory and the speech
/// engine's name, and nothing else. No transcript, history entry or field text can reach it, because there
/// is no parameter that could carry one.
public enum FeedbackReport {
	public enum Kind: Sendable {
		case problem
		case idea
	}

	/// Where the issue form lives; `title` stays empty so the reporter writes it.
	public static let issuesURL = URL(string: "https://github.com/ShankyShako/LegacyScribe/issues/new")!

	/// Plain lines, one fact each, for the issue body or the clipboard.
	public static func diagnostics(
		appVersion: String,
		build: String,
		macOS: String,
		macModel: String,
		memoryGB: Int,
		engine: String
	) -> String {
		[
			"LegacyScribe \(appVersion) (\(build))",
			"macOS \(macOS)",
			"Mac: \(macModel), \(memoryGB) GB memory",
			"Speech engine: \(engine)",
		].joined(separator: "\n")
	}

	/// The prefilled "new issue" page: label `bug` for a problem, `enhancement` for an idea, a short template
	/// and the diagnostics under a rule.
	public static func issueURL(kind: Kind, diagnostics: String) -> URL {
		let template: String
		let label: String
		switch kind {
		case .problem:
			template = "**What happened**\n\n\n**What you expected**\n\n\n---\n"
			label = "bug"
		case .idea:
			template = "**Idea**\n\n\n**Why it would help**\n\n\n---\n"
			label = "enhancement"
		}
		var components = URLComponents(url: issuesURL, resolvingAgainstBaseURL: false)!
		components.queryItems = [
			URLQueryItem(name: "title", value: ""),
			URLQueryItem(name: "labels", value: label),
			URLQueryItem(name: "body", value: template + diagnostics),
		]
		// URLComponents leaves "&", "+" and ";" alone in a query value; GitHub would read them as separators.
		components.percentEncodedQuery = components.percentEncodedQuery?
			.replacingOccurrences(of: "+", with: "%2B")
		return components.url!
	}
}
