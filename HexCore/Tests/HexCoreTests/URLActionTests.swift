import Foundation
import Testing
@testable import HexCore

struct URLActionTests {
	func action(_ string: String) -> URLAction? {
		URL(string: string).flatMap(URLAction.init(url:))
	}

	@Test
	func parsesEveryAction() {
		#expect(action("legacyscribe://start") == .start)
		#expect(action("legacyscribe://stop") == .stop)
		#expect(action("legacyscribe://toggle") == .toggle)
		#expect(action("legacyscribe://cancel") == .cancel)
		#expect(action("legacyscribe://mode/clean") == .mode(.clean))
		#expect(action("legacyscribe://mode/prompt") == .mode(.prompt))
		#expect(action("legacyscribe://mode/raw") == .mode(.raw))
		#expect(action("legacyscribe://mode/notes") == .mode(.notes))
		#expect(action("legacyscribe://notes/start") == .notesStart)
		#expect(action("legacyscribe-debug://notes/stop") == .notesStop)
	}

	@Test
	func ignoresCaseAndATrailingSlash() {
		#expect(action("legacyscribe://Toggle/") == .toggle)
		#expect(action("legacyscribe://MODE/Prompt") == .mode(.prompt))
	}

	@Test
	func rejectsUnknownActions() {
		#expect(action("legacyscribe://") == nil)
		#expect(action("legacyscribe://record") == nil)
		#expect(action("legacyscribe://mode/super") == nil)
		#expect(action("legacyscribe://mode") == nil)
		#expect(action("legacyscribe://start/now") == nil)
		#expect(action("legacyscribe://notes") == nil)
	}

	@Test
	func onlyMicrophoneActionsNeedTheSetting() {
		#expect(URLAction.start.canStartRecording)
		#expect(URLAction.toggle.canStartRecording)
		#expect(URLAction.notesStart.canStartRecording)
		#expect(!URLAction.stop.canStartRecording)
		#expect(!URLAction.cancel.canStartRecording)
		#expect(!URLAction.mode(.clean).canStartRecording)
		#expect(!URLAction.notesStop.canStartRecording)
	}
}
