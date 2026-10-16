import Foundation
@testable import HexCore
import Testing

struct CoachTextTests {
	func words(_ text: String) -> [String] { text.split(separator: " ").map(String.init) }

	@Test
	func countsFillersWithTheirSpellings() {
		let result = CoachText.analyse(words("Um, I think, uh, we should, uhm, go. Hmm. Erm okay. Ah, right."))
		#expect(result.fillers.map(\.kind) == [.um, .uh, .um, .hmm, .er, .ah])
		#expect(result.fillers.map(\.index) == [0, 3, 6, 8, 9, 11])
		#expect(result.words == 7)
	}

	@Test
	func countsCorrectionsSetOffMidSentence() {
		let result = CoachText.analyse(words("Make it two, no, three. Send the red, sorry, the blue one, actually, both."))
		#expect(result.corrections.map(\.kind) == [.no, .sorry, .actually])
	}

	@Test
	func aSentenceStartingWithNoOrActuallyIsNotACorrection() {
		let result = CoachText.analyse(words("No, I haven't. Actually, it went fine. Wait for me. What I mean is simple."))
		#expect(result.corrections.isEmpty)
	}

	@Test
	func countsIMeanScratchThatWaitAndRestarts() {
		let result = CoachText.analyse(words("Call him Monday. I mean, Tuesday. Buy milk scratch that, buy bread. It's the, wait, no wait the the green one."))
		#expect(result.corrections.map(\.kind) == [.repeated, .iMean, .scratchThat, .wait, .wait])
	}

	@Test
	func ordinaryRepeatsAndNumbersDontCountAsRestarts() {
		let result = CoachText.analyse(words("I had had enough, that that is fine, no no, 25 25 is the code."))
		#expect(result.corrections.isEmpty)
	}

	@Test
	func aFillerBetweenTwoCopiesStillReadsAsARestart() {
		#expect(CoachText.analyse(words("I want, um, want the report.")).corrections.map(\.kind) == [.repeated])
	}
}

struct PauseFinderTests {
	let rate = 16_000.0

	/// Tone for `on`, silence for `off`, alternating, in seconds.
	func signal(_ pattern: [(on: Double, off: Double)]) -> [Float] {
		var samples: [Float] = []
		for (on, off) in pattern {
			samples += (0 ..< Int(on * rate)).map { Float(sin(Double($0) * 2 * .pi * 150 / rate)) * 0.3 }
			samples += [Float](repeating: 0.0005, count: Int(off * rate))
		}
		return samples
	}

	@Test
	func findsSilencesOfAtLeastThreeTenths() {
		let silences = PauseFinder.silences(in: signal([(1, 0.5), (1, 0.2), (1, 1.0), (1, 0)]), sampleRate: rate)
		#expect(silences.count == 2)
		#expect(abs(silences[0].lowerBound - 1.0) < 0.03 && abs(silences[0].upperBound - 1.5) < 0.03)
		#expect(abs(silences[1].lowerBound - 3.7) < 0.03 && abs(silences[1].upperBound - 4.7) < 0.03)
	}

	@Test
	func labelsPausesByTheWordBeforeAndIgnoresSilenceAroundTheSpeech() {
		// 0.5 s lead-in, "Hello there." 1 s, pause 0.8 s, "so I" 1 s, pause 0.6 s, "went" 1 s, 1 s tail.
		let samples = signal([(0, 0.5), (1, 0.8), (1, 0.6), (1, 1.0)])
		// TDT-like timings: each word's end runs into the pause and the next start sits inside it.
		let words = [
			SpokenWord(word: "Hello", start: 0.5, end: 1.0),
			SpokenWord(word: "there.", start: 1.0, end: 2.2),
			SpokenWord(word: "so", start: 2.25, end: 2.8),
			SpokenWord(word: "I", start: 2.8, end: 3.7),
			SpokenWord(word: "went", start: 3.75, end: 4.9),
		]
		let pauses = PauseFinder.pauses(in: samples, sampleRate: rate, words: words)
		#expect(pauses.map(\.endsSentence) == [true, false])
		#expect(pauses.count == 2 && abs(pauses[0].seconds - 0.8) < 0.05 && abs(pauses[1].seconds - 0.6) < 0.05)
	}

	@Test
	func aWordPlacedInASilenceDoesNotVetoIt() {
		// Speech 1 s, a quiet 1.2 s, speech 1 s. Parakeet writes words into a flat noise floor, so a word
		// inside the silence doesn't make it speech.
		let samples = signal([(1, 1.2), (1, 0)])
		let words = [
			SpokenWord(word: "Hello", start: 0, end: 1.0),
			SpokenWord(word: "over", start: 1.5, end: 2.1),
			SpokenWord(word: "there", start: 2.1, end: 2.2),
			SpokenWord(word: "friend.", start: 2.2, end: 3.2),
		]
		#expect(PauseFinder.pauses(in: samples, sampleRate: rate, words: words).count == 1)
	}
}

struct CoachSummaryTests {
	let calendar: Calendar = {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(identifier: "UTC")!
		calendar.firstWeekday = 2
		return calendar
	}()

	func clip(
		day: Int, mode: String? = "clean", app: String? = "Notes", words: Int = 100, seconds: Double = 40,
		fillers: [String: Int] = [:], offsets: [Double] = [], corrections: [String: Int] = [:],
		sentence: [Double] = [], thought: [Double] = []
	) -> CoachClip {
		CoachClip(
			dictationID: UUID(), date: Date(timeIntervalSince1970: 1_791_763_200 + Double(day) * 86400), // Mon 12 Oct 2026
			mode: mode, appName: app, engine: "parakeet", words: words, speakingSeconds: seconds,
			fillers: fillers, fillerOffsets: offsets, corrections: corrections, sentencePauses: sentence, thoughtPauses: thought
		)
	}

	@Test
	func addsUpRatesWeeksModesAndApps() {
		let summary = CoachSummary([
			clip(day: 0, fillers: ["um": 2], offsets: [0.5, 10], sentence: [1.0], thought: [0.4]),
			clip(day: 1, mode: "prompt", app: "Slack", fillers: ["um": 1, "uh": 1], offsets: [1, 1.5], corrections: ["no": 1], thought: [0.6]),
			clip(day: 7, fillers: ["uh": 1], offsets: [20]),
			clip(day: 8, words: 0, seconds: 0),
		], calendar: calendar)
		#expect(summary.overall.dictations == 3)
		#expect(summary.overall.words == 300)
		#expect(summary.overall.fillersPer100Words == 5.0 / 3)
		#expect(summary.overall.wordsPerMinute == 150)
		#expect(abs(summary.overall.speakingWordsPerMinute! - 300 / 118.0 * 60) < 1e-9)
		#expect(summary.overall.medianThoughtPause == 0.5)
		#expect(summary.overall.medianSentencePause == 1.0)
		#expect(summary.overall.longestPause == 1.0)
		#expect(summary.fillers == [.init(name: "um", count: 3), .init(name: "uh", count: 2)])
		#expect(summary.corrections == [.init(name: "no", count: 1)])
		#expect(summary.openingFillerShare == 0.6)
		#expect(summary.weeks.map(\.rates.dictations) == [2, 1])
		#expect(summary.byMode.map(\.name) == ["clean", "prompt"])
		#expect(summary.byApp.map(\.name) == ["Notes", "Slack"])
	}

	@Test
	func tipsWaitForEnoughWords() {
		let tips = CoachSummary([clip(day: 0, words: 50, fillers: ["um": 10])], calendar: calendar).tips
		#expect(tips.count == 1 && tips[0].contains("50 words"))
	}

	@Test
	func tipsNameTheMainHabits() {
		let summary = CoachSummary([
			clip(day: 0, words: 150, seconds: 60, fillers: ["um": 5, "uh": 2], offsets: [0.2, 0.5, 1, 1.2, 1.5, 1.8, 9], corrections: ["no": 5]),
			clip(day: 1, words: 150, seconds: 60, thought: [1.5, 1.1, 0.4]),
		], calendar: calendar)
		#expect(summary.tips.count == 4)
		#expect(summary.tips[0].contains("about 2.3 times per 100 words, “um” most"))
		#expect(summary.tips.contains { $0.contains("86% of your fillers") })
		#expect(summary.tips.contains { $0.contains("correct yourself") })
		#expect(summary.tips.contains { $0.contains("inside a sentence lasts 1.1 s") })
	}

	@Test
	func paceLeavesThePausesOut() {
		// 240 words in 120 s with 40 s of pauses: 120 a minute with them, 180 without, so no "slow" tip.
		let summary = CoachSummary([clip(day: 0, words: 240, seconds: 120, sentence: [20, 10], thought: [5, 5])], calendar: calendar)
		#expect(summary.overall.wordsPerMinute == 120)
		#expect(summary.overall.speakingWordsPerMinute == 180)
		#expect(!summary.tips.contains { $0.contains("words a minute") })
	}

	@Test
	func calmSpeechGetsNoNagging() {
		let tips = CoachSummary([clip(day: 0, words: 300, seconds: 120, fillers: ["um": 1], offsets: [5])], calendar: calendar).tips
		#expect(tips == ["Nothing stands out: your fillers, corrections and pace are all in an easy range."])
	}
}

struct CoachStoreTests {
	@Test
	func clipsAreStoredReplacedAndDeletedWithTheirDictation() throws {
		let store = try ScribeStore()
		let a = Transcript(timestamp: Date(), text: "a", audioPath: URL(fileURLWithPath: "/tmp/a.flac"), duration: 2)
		let b = Transcript(timestamp: Date(), text: "b", audioPath: URL(fileURLWithPath: "/tmp/b.flac"), duration: 2)
		try store.sync([a, b], previous: [])
		var clipA = CoachClip(dictationID: a.id, date: a.timestamp, engine: "parakeet", words: 10, speakingSeconds: 4, fillers: ["um": 1])
		let clipB = CoachClip(dictationID: b.id, date: b.timestamp, engine: "parakeet", words: 5, speakingSeconds: 2)
		let orphan = CoachClip(dictationID: UUID(), date: Date(), engine: "parakeet", words: 5, speakingSeconds: 2)
		try store.saveCoachClips([clipA, clipB, orphan])
		#expect(Set(try store.coachClips().map(\.dictationID)) == [a.id, b.id])

		clipA.fillers = ["uh": 2]
		try store.saveCoachClips([clipA])
		#expect(try store.coachClips().first { $0.dictationID == a.id }?.fillers == ["uh": 2])

		try store.sync([b], previous: [a, b])
		#expect(try store.coachClips().map(\.dictationID) == [b.id])
		try store.deleteCoachClips()
		#expect(try store.coachClips().isEmpty)
	}
}

struct CoachCrutchTests {
	func words(_ text: String) -> [String] { text.split(separator: " ").map(String.init) }

	@Test
	func countsCrutchWordsOnlyInTheirFillerUse() {
		let result = CoachText.analyse(words(
			"It's, like, basically done, you know, and I just need, kind of, a minute, right? I like it, it looks like rain, what kind of car, do you know, just in time, literally."
		))
		#expect(result.crutches.map(\.kind) == [.like, .basically, .youKnow, .just, .kindOf, .right, .literally])
	}

	@Test
	func countsRestartedPhrasesAsRepeats() {
		func repeats(_ text: String) -> Int {
			CoachText.analyse(words(text)).corrections.filter { $0.kind == .repeated }.count
		}
		// From the user's History: restarts the single-word check missed.
		#expect(repeats("Yes, you can you can go forward.") == 1)
		#expect(repeats("'Cause I w I was able to get it working.") == 1)
		#expect(repeats("The user changes their m their mind.") == 1)
		#expect(repeats("If you want to do if you want to opt out, you can.") == 1)
		#expect(repeats("After that we can, um, we can start.") == 1)
		// Parallel phrasing, idioms and a word around another one aren't restarts.
		#expect(repeats("It depends on how many people are online, how many people are viewing it.") == 0)
		#expect(repeats("We went one by one, day to day.") == 0)
		#expect(repeats("And when they click it again, it will show the list.") == 0)
		#expect(repeats("Let's see what words we can condense and what words we can remove.") == 0)
	}

	@Test
	func countsSoAndOhOnlyWhenTheyOpenASentence() {
		let result = CoachText.analyse(words(
			"So, I went home. Oh, then there is the bill. Um, so we paid. So far so good. It was so late. Oh no."
		))
		#expect(result.crutches.map(\.kind) == [.so, .oh, .so, .oh])
		#expect(result.crutches.map(\.index) == [0, 4, 11, 22])
	}

	@Test
	func countsHedgesButNotThinkingAbout() {
		let result = CoachText.analyse(words("I think we should go. Maybe later. I guess so. I think about it a lot. I feel like it's fine, perhaps."))
		#expect(result.hedges.map(\.kind) == [.iThink, .maybe, .iGuess, .iFeelLike, .perhaps])
		// "feel like" is a hedge, not a crutch "like".
		#expect(result.crutches.isEmpty)
	}

	@Test
	func findsRunOnsByLengthAndAnds() {
		let long = (0 ..< 13).map { "word\($0) and more" }.joined(separator: " ") + "."
		let result = CoachText.analyse(words("Short one. \(long) Another, um, short one."))
		#expect(result.sentences.map(\.words) == [2, 39, 3])
		#expect(result.sentences[1].ands == 13 && !result.sentences[1].isRunOn)
		let longer = CoachText.analyse(words(long.replacingOccurrences(of: ".", with: "") + " end."))
		#expect(longer.sentences.count == 1 && longer.sentences[0].isRunOn)
	}
}

struct CoachClipTests {
	@Test
	func momentsCarryTheirTimeInTheRecording() {
		let words = [
			SpokenWord(word: "Um,", start: 0.4, end: 0.7), SpokenWord(word: "it's", start: 0.8, end: 1.0),
			SpokenWord(word: "basically", start: 1.0, end: 1.5), SpokenWord(word: "done.", start: 1.5, end: 2.0),
		]
		let transcript = Transcript(timestamp: Date(), text: "", audioPath: URL(fileURLWithPath: "/tmp/x.wav"), duration: 2)
		let clip = SpeechCoach.clip(for: transcript, engine: "parakeet-v3", words: words, samples: [], sampleRate: 16000)
		#expect(clip.moments == [
			CoachMoment(kind: .filler, label: "um", time: 0.4),
			CoachMoment(kind: .crutch, label: "basically", time: 1.0),
		])
		#expect(clip.crutches == ["basically": 1] && clip.sentenceLengths == [3] && clip.version == CoachClip.currentVersion)
	}

	@Test
	func aCleanSentenceIsTheGoodExample() {
		// "Um, it was fine." then a clean 10-word sentence, then one with "just" in it.
		let text = "Um, it was fine. We walked along the river until the sun went down. I just wanted to see the boats come in."
		var time = 0.0
		let words = text.split(separator: " ").map { word -> SpokenWord in
			defer { time += 0.4 }
			return SpokenWord(word: String(word), start: time, end: time + 0.4)
		}
		let transcript = Transcript(timestamp: Date(), text: "", audioPath: URL(fileURLWithPath: "/tmp/x.wav"), duration: time)
		let clip = SpeechCoach.clip(for: transcript, engine: "parakeet-v3", words: words, samples: [], sampleRate: 16000)
		let fluent = clip.moments.filter { $0.kind == .fluent }
		#expect(fluent.count == 1)
		#expect(abs(fluent[0].time - 1.6) < 0.001 && abs((fluent[0].seconds ?? 0) - 4.0) < 0.001)
		#expect(!clip.moments.contains { $0.kind == .pause })
	}

	@Test
	func aQuietStretchIsNotAGoodExample() {
		let rate = 16_000.0
		// Ten words of 0.4 s; the last three quiet, as if said away from the microphone.
		let words = (0 ..< 10).map { (index: Int) -> SpokenWord in
			let start = Double(index) * 0.4
			return SpokenWord(word: index == 9 ? "end." : "word\(index)", start: start, end: start + 0.4)
		}
		let samples = (0 ..< Int(4 * rate)).map { index -> Float in
			let tone = Float(sin(Double(index) * 2 * Double.pi * 150 / rate))
			let gain: Float = Double(index) / rate < 2.8 ? 0.3 : 0.02
			return tone * gain
		}
		let even: [Float] = samples.map { $0 == 0 ? 0 : ($0 > 0 ? 0.3 : -0.3) }
		let transcript = Transcript(timestamp: Date(), text: "", audioPath: URL(fileURLWithPath: "/tmp/x.wav"), duration: 4)
		let quiet = SpeechCoach.clip(for: transcript, engine: "parakeet-v3", words: words, samples: samples, sampleRate: rate)
		#expect(!quiet.moments.contains { $0.kind == CoachMoment.Kind.fluent })
		let steady = SpeechCoach.clip(for: transcript, engine: "parakeet-v3", words: words, samples: even, sampleRate: rate)
		#expect(steady.moments.contains { $0.kind == CoachMoment.Kind.fluent })
	}

	@Test
	func clipsFromTheFirstVersionStillDecode() throws {
		let json = #"{"dictationID":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","date":0,"engine":"parakeet","words":10,"speakingSeconds":4,"fillers":{"um":1},"fillerOffsets":[0.5],"corrections":{},"sentencePauses":[],"thoughtPauses":[]}"#
		let clip = try JSONDecoder().decode(CoachClip.self, from: Data(json.utf8))
		#expect(clip.version == 1 && clip.fillers == ["um": 1] && clip.moments.isEmpty && clip.crutches.isEmpty)
	}

	@Test
	func aWordIsMisheardOnlyWhenBothEnginesMissItDifferently() {
		// Cohere wrote "can", the user sent "can't"; Parakeet wrote "cat": neither engine heard it.
		#expect(CoachMisheard.find(pasted: "I can go there.", sent: "I can't go there.", coachWords: ["I", "cat", "go", "there."])
			== [CoachMisheard(said: "can't", heard: "can")])
		// Parakeet agreed with Cohere: an edit or a shared blind spot, not counted.
		#expect(CoachMisheard.find(pasted: "I can go there.", sent: "I can't go there.", coachWords: ["I", "can", "go", "there."]).isEmpty)
		// Parakeet got it right: the dictation engine's mistake alone.
		#expect(CoachMisheard.find(pasted: "I can go there.", sent: "I can't go there.", coachWords: ["I", "can't", "go", "there."]).isEmpty)
	}

	@Test
	func misheardWordsNeedAnotherEngineFamily() {
		let transcript = Transcript(timestamp: Date(), text: "", audioPath: URL(fileURLWithPath: "/tmp/x.wav"), duration: 2)
		let edit = SentEdit(timestamp: Date(), transcriptID: transcript.id, bundleID: nil, appName: nil, mode: nil, recognized: "I can go", pasted: "I can go.", sent: "I can't go.")
		let words = [SpokenWord(word: "I", start: 0, end: 0.2), SpokenWord(word: "cat", start: 0.2, end: 0.5), SpokenWord(word: "go.", start: 0.5, end: 0.8)]
		let cohere = SpeechCoach.clip(for: transcript, engine: "parakeet-tdt-0.6b-v3", words: words, samples: [], sampleRate: 16000, sentEdit: edit, dictationEngine: "cohere-transcribe-4bit")
		let parakeet = SpeechCoach.clip(for: transcript, engine: "parakeet-tdt-0.6b-v3", words: words, samples: [], sampleRate: 16000, sentEdit: edit, dictationEngine: "parakeet-tdt-0.6b-v2")
		#expect(cohere.misheard.count == 1 && parakeet.misheard.isEmpty)
	}
}

struct CoachSummaryExtrasTests {
	func clip(day: Int, words: Int = 300, corrections: [String: Int] = [:], thought: [Double] = [], crutches: [String: Int] = [:],
	          runOns: Int = 0, sentences: Int = 20, moments: [CoachMoment] = [], misheard: [CoachMisheard] = []) -> CoachClip {
		CoachClip(
			dictationID: UUID(), date: Date(timeIntervalSince1970: 1_791_763_200 + Double(day) * 86400), engine: "parakeet",
			words: words, speakingSeconds: 120, corrections: corrections, thoughtPauses: thought, crutches: crutches,
			sentenceLengths: Array(repeating: 15, count: sentences), runOns: runOns, moments: moments, misheard: misheard
		)
	}

	@Test
	func stutterFriendlyLeavesRepeatsAndInnerPausesOut() {
		let clips = [clip(
			day: 0, corrections: ["repeated": 9, "no": 1], thought: [1.5, 1.2, 2.0],
			moments: [CoachMoment(kind: .correction, label: "repeated", time: 1), CoachMoment(kind: .pause, label: "", time: 2), CoachMoment(kind: .filler, label: "um", time: 3)]
		)]
		let plain = CoachSummary(clips)
		let friendly = CoachSummary(clips, stutterFriendly: true)
		#expect(plain.overall.corrections == 10 && friendly.overall.corrections == 1)
		#expect(plain.tips.contains { $0.contains("inside a sentence") })
		#expect(!friendly.tips.contains { $0.contains("inside a sentence") || $0.contains("correct yourself") })
		#expect(friendly.examples.map(\.moment.kind) == [.filler])
	}

	@Test
	func crutchAndRunOnTipsAndRecentRunOns() {
		let now = Date(timeIntervalSince1970: 1_791_763_200 + 10 * 86400)
		let summary = CoachSummary([
			clip(day: 0, crutches: ["just": 4], runOns: 2),
			clip(day: 9, crutches: ["just": 2, "like": 1], runOns: 2),
		], now: now)
		#expect(summary.crutches.first == .init(name: "just", count: 6))
		#expect(summary.overall.crutchesPer100Words == 7.0 / 6)
		#expect(summary.recentRunOns == 2)
		#expect(summary.tips.contains { $0.hasPrefix("“Just” shows up 1.0 times per 100 words") })
		#expect(summary.tips.contains { $0.hasPrefix("4 of your sentences run 40+ words") })
	}

	@Test
	func misheardWordsAddUpWithoutTheVocabulary() {
		let summary = CoachSummary([
			clip(day: 0, misheard: [.init(said: "can't", heard: "can"), .init(said: "Syncthing", heard: "sync thing")]),
			clip(day: 1, misheard: [.init(said: "Can't", heard: "can")]),
		], vocabulary: ["syncthing"])
		#expect(summary.misheard == [.init(said: "can't", heard: "can", count: 2)])
	}
}

struct PitchTrackerTests {
	let rate = 16_000.0

	/// A voiced-like tone (fundamental plus two harmonics) whose pitch glides from `from` to `to` Hz.
	func glide(from: Double, to: Double, seconds: Double) -> [Float] {
		var phase = 0.0
		return (0 ..< Int(seconds * rate)).map { n in
			let f = from + (to - from) * Double(n) / (seconds * rate)
			phase += 2 * .pi * f / rate
			return Float(0.3 * sin(phase) + 0.15 * sin(2 * phase) + 0.08 * sin(3 * phase))
		}
	}

	@Test
	func measuresTheSpreadOfAGlide() throws {
		// 120 → 180 Hz is 7.0 semitones; the 10th–90th percentile spread is about 80% of it.
		let range = try #require(PitchTracker.semitoneRange(samples: glide(from: 120, to: 180, seconds: 4), sampleRate: rate))
		#expect(range > 5.0 && range < 6.2, "range \(range)")
	}

	@Test
	func aSteadyToneHasNoRangeAndSilenceHasNone() throws {
		let range = try #require(PitchTracker.semitoneRange(samples: glide(from: 150, to: 150, seconds: 3), sampleRate: rate))
		#expect(range < 0.5)
		#expect(PitchTracker.semitoneRange(samples: [Float](repeating: 0, count: 48000), sampleRate: rate) == nil)
	}
}

struct CoachMinuteTests {
	@Test
	func theBestRunHasFewestFillersAndEnoughWords() {
		let date = Date()
		let runs = [
			CoachMinute(date: date, topic: "a", engine: "p", words: 150, speakingSeconds: 55, fillers: ["um": 2]),
			CoachMinute(date: date, topic: "b", engine: "p", words: 30, speakingSeconds: 20),
			CoachMinute(date: date, topic: "c", engine: "p", words: 120, speakingSeconds: 55, fillers: ["uh": 1]),
			CoachMinute(date: date, topic: "d", engine: "p", words: 140, speakingSeconds: 55, fillers: ["um": 1]),
		]
		#expect(CoachMinute.best(of: runs)?.topic == "d")
	}

	@Test
	func minutesAreStoredAndDeletedWithTheCoachData() throws {
		let store = try ScribeStore()
		let older = CoachMinute(date: Date(timeIntervalSince1970: 0), topic: "a", engine: "p", words: 100, speakingSeconds: 50)
		let newer = CoachMinute(date: Date(timeIntervalSince1970: 100), topic: "b", engine: "p", words: 90, speakingSeconds: 50, pitchRange: 6.2)
		try store.saveCoachMinute(newer)
		try store.saveCoachMinute(older)
		#expect(try store.coachMinutes() == [older, newer])
		try store.deleteCoachClips()
		#expect(try store.coachMinutes().isEmpty)
	}
}
