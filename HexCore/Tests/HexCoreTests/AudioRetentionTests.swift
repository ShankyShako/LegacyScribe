import Foundation
@testable import HexCore
import Testing

struct AudioRetentionTests {
	let now = Date(timeIntervalSince1970: 1_800_000_000)

	func transcript(daysAgo: Double, audioRemoved: Bool? = nil) -> Transcript {
		Transcript(
			timestamp: now.addingTimeInterval(-daysAgo * 86_400),
			text: "hello",
			audioPath: URL(fileURLWithPath: "/tmp/\(daysAgo).wav"),
			duration: 1,
			audioRemoved: audioRemoved
		)
	}

	func edit(_ transcriptID: UUID?, pasted: String, sent: String) -> SentEdit {
		SentEdit(timestamp: now, transcriptID: transcriptID, bundleID: nil, appName: nil, mode: nil, recognized: pasted, pasted: pasted, sent: sent)
	}

	@Test
	func onlyAudioPastTheCutoffExpires() {
		let old = transcript(daysAgo: 31)
		let recent = transcript(daysAgo: 29)
		#expect(AudioRetention.expired([recent, old], pinned: [], days: 30, now: now) == [old.id])
	}

	@Test
	func zeroDaysKeepsEverything() {
		let old = transcript(daysAgo: 400)
		#expect(AudioRetention.expired([old], pinned: [], days: 0, now: now).isEmpty)
		#expect(AudioRetention.orphans(files: [(URL(fileURLWithPath: "/tmp/x.wav"), .distantPast)], referenced: [], days: 0, now: now).isEmpty)
	}

	@Test
	func alreadyRemovedAudioIsSkipped() {
		#expect(AudioRetention.expired([transcript(daysAgo: 60, audioRemoved: true)], pinned: [], days: 30, now: now).isEmpty)
	}

	@Test
	func editedSentTextPinsItsRecording() {
		let edited = transcript(daysAgo: 60)
		let unedited = transcript(daysAgo: 60)
		let edits = [
			edit(edited.id, pasted: "Ship it today.", sent: "Ship it tomorrow."),
			edit(unedited.id, pasted: "Ship it.", sent: " Ship it. "),
			edit(nil, pasted: "a", sent: "b"),
		]
		let pinned = AudioRetention.pinned(by: edits)
		#expect(pinned == [edited.id])
		#expect(AudioRetention.expired([edited, unedited], pinned: pinned, days: 30, now: now) == [unedited.id])
	}

	@Test
	func orphansAreOldFilesNoEntryPointsAt() {
		let kept = URL(fileURLWithPath: "/data/Recordings/1.wav")
		let orphan = URL(fileURLWithPath: "/data/Recordings/2.wav")
		let fresh = URL(fileURLWithPath: "/data/Recordings/3.wav")
		let old = now.addingTimeInterval(-40 * 86_400)
		let files = [(kept, old), (orphan, old), (fresh, now)]
		let referenced: Set<String> = [kept.path]
		#expect(AudioRetention.orphans(files: files, referenced: referenced, days: 30, now: now) == [orphan])
	}

	@Test
	func historySavedBeforeRetentionStillDecodes() throws {
		let json = #"{"history":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","timestamp":0,"text":"hi","audioPath":"file:///tmp/a.wav","duration":1}]}"#
		let history = try JSONDecoder().decode(TranscriptionHistory.self, from: Data(json.utf8))
		#expect(history.history.first?.audioRemoved == nil)
	}

	@Test
	func settingsWithoutTheKeyDefaultToThirtyDays() throws {
		let settings = try JSONDecoder().decode(HexSettings.self, from: Data("{}".utf8))
		#expect(settings.audioRetentionDays == 30)
	}
}
