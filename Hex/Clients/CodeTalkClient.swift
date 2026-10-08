import Dependencies
import DependenciesMacros
import Foundation
import HexCore

/// Slash commands Prompt mode's code talk knows: Claude Code's built-ins plus the user's skills and
/// commands in `~/.claude`, read on each Prompt dictation so a new skill is known right away.
@DependencyClient
struct CodeTalkClient {
	var slashCommands: @Sendable () -> [String] = { [] }
}

extension CodeTalkClient: DependencyKey {
	static var liveValue: Self {
		Self(slashCommands: {
			let claudeFolder = FileManager.default.homeDirectoryForCurrentUser
				.appendingPathComponent(".claude", isDirectory: true)
			let userCommands = CodeTalk.slashCommands(inClaudeFolder: claudeFolder)
			return Array(Set(CodeTalk.builtInSlashCommands + userCommands)).sorted()
		})
	}

	static var testValue: Self { Self(slashCommands: { [] }) }
}

extension DependencyValues {
	var codeTalk: CodeTalkClient {
		get { self[CodeTalkClient.self] }
		set { self[CodeTalkClient.self] = newValue }
	}
}
