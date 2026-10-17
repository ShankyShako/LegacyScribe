#if DEBUG
import AVFoundation
import ComposableArchitecture
import Foundation
import HexCore
import WhisperKit

/// Notes mode's tap-versus-hold behaviour (P3.6 D1) on real engines and a real recording, with no
/// microphone, no real key presses and no paste. Debug builds only; the data root comes from
/// `LEGACYSCRIBE_DATA_ROOT` so a run never touches the user's settings or sessions.
///
///     "LegacyScribe Debug" --notes-harness taps <file.wav> --script "p; w 0.15; r; w 60; p; w 0.15; r"
///         [--offset 100]        where in the file dictations are cut from (seconds)
///         [--feed-offset 0]     where a Notes session's audio starts in the file
///         [--speed 1]           feed speed for Notes sessions (1 = real time)
///         [--before raw|clean]  the mode picked before Notes, which a held dictation uses
///         [--until transcript|done]  how far a kept session must get before the run ends
///         [--reference]         also transcribe each dictation's audio with Cohere, as an independent check
///
/// Script steps (separated by `;`): `p` press the talk key, `r` release it, `w <seconds>` wait, `esc` press Esc,
/// `s` log the reducer's state. A wait starts when the step before it is done, so `p; w 0.25; r` holds the key
/// for 0.25 s plus the sleep's overshoot (a few milliseconds, logged as `heldSeconds`). The keys go through the real `startHotKeyMonitoringEffect` (a fake
/// `KeyEventMonitorClient` delivers them to its handlers), so `NotesTapDetector` and `HotKeyProcessor` run
/// as in the app. Recording is replaced by cutting the held time out of the file, a running offset;
/// paste, sound and the focused-field reads are replaced by log lines or nothing. Transcription, the
/// Notes engine and the rewrite are the live ones.
///
/// Prints one JSON object per line: every key, recording, transcription, paste, sound and Notes call
/// with its time in seconds, then a `summary`. Exits 0 once the script and everything it started is done.
enum NotesTapHarness {
	static func run(_ arguments: [String]) async -> Int32 {
		do {
			guard let wavPath = arguments.first, !wavPath.hasPrefix("--") else { throw HarnessError("taps needs a WAV path") }
			func value(_ name: String) -> String? {
				arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
			}
			guard let script = value("--script") else { throw HarnessError("taps needs --script") }
			let steps = try parse(script)
			let options = Options(
				wav: URL(fileURLWithPath: wavPath),
				dictationOffset: Double(value("--offset") ?? "") ?? 60,
				feedOffset: Double(value("--feed-offset") ?? "") ?? 0,
				speed: Double(value("--speed") ?? "") ?? 1,
				before: value("--before") == "clean" ? .clean : .raw,
				untilDone: value("--until") == "done",
				reference: arguments.contains("--reference"),
				timeout: Double(value("--timeout") ?? "") ?? 240
			)
			return try await Runner(options: options, steps: steps).run()
		} catch {
			print(json(["event": "error", "message": error.localizedDescription]))
			return 1
		}
	}

	// MARK: - Script

	enum Step {
		case press, release, escape, state
		case wait(Double)
	}

	static func parse(_ script: String) throws -> [Step] {
		try script.split(separator: ";").map { raw in
			let parts = raw.split(separator: " ").map(String.init)
			switch (parts.first, parts.count) {
			case ("p", 1): return .press
			case ("r", 1): return .release
			case ("esc", 1): return .escape
			case ("s", 1): return .state
			case ("w", 2):
				guard let seconds = Double(parts[1]) else { fallthrough }
				return .wait(seconds)
			default: throw HarnessError("bad script step: \(raw)")
			}
		}
	}

	struct Options {
		var wav: URL
		var dictationOffset: Double
		var feedOffset: Double
		var speed: Double
		var before: RewriteMode
		var untilDone: Bool
		var reference: Bool
		var timeout: Double
	}

	// MARK: - Runner

	private final class Runner: @unchecked Sendable {
		let options: Options
		let steps: [Step]
		let log = EventLog()
		let keys = FakeKeyMonitor()
		let engine = NotesEngine()
		let source: ExcerptSource
		let feed: NotesFeed
		let pasted = Locked<[String]>([])
		let copied = Locked<[String]>([])
		let transcribed = Locked<[(text: String, audio: URL?)]>([])

		init(options: Options, steps: [Step]) {
			self.options = options
			self.steps = steps
			source = ExcerptSource(url: options.wav, offset: options.dictationOffset)
			feed = NotesFeed(url: options.wav, offset: options.feedOffset, speed: options.speed)
		}

		func run() async throws -> Int32 {
			// Settings in the scratch root: Notes mode, with `before` as the mode a hold dictates in.
			@Shared(.hexSettings) var settings: HexSettings
			$settings.withLock {
				$0.rewriteMode = options.before
				$0.rewriteMode = .notes
				$0.contextTermsEnabled = false
				$0.superEnabled = false
				$0.matchSurroundingText = false
				$0.captureSentEdits = false
				$0.mergeIntoFieldEnabled = false
				$0.soundEffectsEnabled = false
				$0.superFastModeEnabled = false
				$0.rewriteFallbackEnabled = false
			}
			let hotkey = settings.hotkey
			log.emit("settings", [
				"dictationMode": settings.dictationMode.rawValue, "rewriteMode": settings.rewriteMode.rawValue,
				"model": settings.selectedModel, "hotkey": "\(hotkey)",
				"dataRoot": (try? URL.hexApplicationSupport.path) ?? "?",
			])

			let history = Shared(value: TranscriptionHistory())
			let (monitor, recording, transcription, pasteboard, sounds, notes) =
				(keys.client, recordingClient(), transcriptionClient(), pasteboardClient(), soundClient(), notesClient())
			let store = await MainActor.run {
				Store(
					initialState: TranscriptionFeature.State(
						hexSettings: $settings,
						isRemappingScratchpadFocused: false,
						modelBootstrapState: Shared(value: .init(isModelReady: true)),
						transcriptionHistory: history
					)
				) {
					TranscriptionFeature()
				} withDependencies: {
					$0.keyEventMonitor = monitor
					$0.recording = recording
					$0.transcription = transcription
					$0.pasteboard = pasteboard
					$0.soundEffects = sounds
					$0.notes = notes
					$0.sleepManagement = SleepManagementClient(preventSleep: { _ in }, allowSleep: {})
					$0.focusedText = FocusedTextClient(read: { nil }, frontmostBundleID: { nil })
				}
			}
			await MainActor.run { _ = store.send(.task) }
			// The hotkey effect registers its handlers asynchronously.
			let ready = ContinuousClock.now + .seconds(10)
			while !keys.isReady, ContinuousClock.now < ready { try await Task.sleep(for: .milliseconds(20)) }
			guard keys.isReady else { throw HarnessError("the hotkey handlers never registered") }
			log.emit("ready")

			var pressedAt: ContinuousClock.Instant?
			for step in steps {
				switch step {
				case .wait(let seconds):
					try await Task.sleep(until: .now + .seconds(seconds), clock: .continuous)
				case .press:
					pressedAt = ContinuousClock.now
					log.emit("key.press")
					keys.send(KeyEvent(key: hotkey.key, modifiers: hotkey.modifiers))
				case .release:
					let held = pressedAt.map { EventLog.seconds(ContinuousClock.now - $0) }
					log.emit("key.release", held.map { ["heldSeconds": $0] } ?? [:])
					keys.send(KeyEvent(key: nil, modifiers: []))
				case .state:
					log.emit("state", await stateFields(store))
				case .escape:
					log.emit("key.escape")
					keys.send(KeyEvent(key: .escape, modifiers: []))
				}
			}
			log.emit("script.done")

			try await settle(store)
			return try await summarize(store, history: history)
		}

		// MARK: Waiting

		private func stateFields(_ store: StoreOf<TranscriptionFeature>) async -> [String: Any] {
			await MainActor.run {
				store.withState { state in
					[
						"isRecording": state.isRecording, "isTranscribing": state.isTranscribing,
						"isRewriting": state.isRewriting, "notesHold": state.notesHold,
						"notesSession": state.notesRecording != nil, "notesSessionID": state.notesRecording?.id ?? "",
					]
				}
			}
		}

		private func snapshot(_ store: StoreOf<TranscriptionFeature>) async -> (busy: Bool, text: String) {
			await MainActor.run {
				store.withState { state in
					let busy = state.isRecording || state.isTranscribing || state.isRewriting || state.notesRecording != nil
					return (busy, "recording=\(state.isRecording) transcribing=\(state.isTranscribing) rewriting=\(state.isRewriting) session=\(state.notesRecording != nil)")
				}
			}
		}

		/// Until the app is idle for a moment and every kept session has its transcript (or its notes).
		private func settle(_ store: StoreOf<TranscriptionFeature>) async throws {
			let limit = ContinuousClock.now + .seconds(options.timeout)
			var idleSince: ContinuousClock.Instant?
			try await Task.sleep(for: .milliseconds(500))
			while ContinuousClock.now < limit {
				let state = await snapshot(store)
				let sessions = await engine.list()
				let sessionsDone = sessions.allSatisfy { summary in
					if summary.session.notesError != nil { return true }
					switch summary.session.stage {
					case .recording: return false
					case .transcribing: return false
					case .noting: return !options.untilDone && summary.pendingChunks == 0
					case .done: return true
					}
				}
				if !state.busy, sessionsDone {
					if idleSince == nil { idleSince = .now }
					if ContinuousClock.now - idleSince! >= .seconds(1) { return }
				} else {
					idleSince = nil
				}
				try await Task.sleep(for: .milliseconds(200))
			}
			log.emit("settle.timeout")
		}

		// MARK: Summary

		private func summarize(_ store: StoreOf<TranscriptionFeature>, history: Shared<TranscriptionHistory>) async throws -> Int32 {
			let sessions = await engine.list()
			var sessionInfo: [[String: Any]] = []
			for summary in sessions {
				let content = await engine.content(summary.id)
				let words = content.transcript.split(whereSeparator: \.isWhitespace).count
				sessionInfo.append([
					"id": summary.id, "stage": summary.session.stage.rawValue,
					"transcribedChunks": summary.transcribedChunks, "pendingChunks": summary.pendingChunks,
					"gaps": summary.gaps, "transcriptWords": words, "speakers": summary.speakerCount,
					"notesError": summary.session.notesError ?? "", "notesWritten": content.notes != nil,
					"transcriptHead": String(content.transcript.prefix(160)),
				])
			}
			let root = URL.notesFolderURL
			let folders = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
			let entries = history.wrappedValue.history.map { entry -> [String: Any] in
				[
					"text": entry.text, "rawText": entry.rawText ?? "", "rewriteMode": entry.rewriteMode?.rawValue ?? "",
					"rewrittenBy": entry.rewrittenBy ?? "", "duration": entry.duration,
				]
			}
			var references: [[String: Any]] = []
			if options.reference {
				let cohere = transcriptionClient(plain: true)
				for item in transcribed.value {
					guard let audio = item.audio else { continue }
					let started = ContinuousClock.now
					let text = try await cohere.transcribe(audio, CohereModel.fourBit.identifier, DecodingOptions(), { _ in })
					references.append(["engineText": item.text, "referenceText": text, "seconds": EventLog.seconds(ContinuousClock.now - started)])
				}
			}
			let state = await snapshot(store)
			source.cleanup()
			log.emit("summary", [
				"pasted": pasted.value, "copied": copied.value, "history": entries,
				"notesFolders": folders, "sessions": sessionInfo, "references": references,
				"finalState": state.text, "footprint": NotesEngine.footprint(),
			])
			return 0
		}

		// MARK: Dependency overrides

		private func recordingClient() -> RecordingClient {
			var client = RecordingClient()
			let startedAt = Locked<ContinuousClock.Instant?>(nil)
			client.startRecording = { [self] in
				startedAt.value = .now
				log.emit("recording.start")
			}
			client.stopRecording = { [self] in
				guard let began = startedAt.value else {
					log.emit("recording.stop", ["captured": false])
					return .ignored(.noActiveRecording)
				}
				startedAt.value = nil
				let held = EventLog.seconds(ContinuousClock.now - began)
				do {
					let cut = try source.next(seconds: held)
					log.emit("recording.stop", [
						"captured": true, "heldSeconds": held, "fromSecond": cut.start, "seconds": cut.length,
					])
					return .captured(cut.url)
				} catch {
					log.emit("recording.stop", ["captured": false, "error": error.localizedDescription])
					return .failed(.noCapturedAudio)
				}
			}
			return client
		}

		/// The live engines; with `plain` no logging (the reference pass).
		private func transcriptionClient(plain: Bool = false) -> TranscriptionClient {
			var client = TranscriptionClient.liveValue
			let live = client.transcribe
			let kept = source
			client.transcribe = { [self] url, model, options, progress in
				let started = ContinuousClock.now
				let text = try await live(url, model, options, progress)
				guard !plain else { return text }
				transcribed.withValue { $0.append((text, kept.keepCopy(of: url))) }
				log.emit("transcribe", [
					"model": model, "seconds": EventLog.seconds(ContinuousClock.now - started),
					"words": text.split(whereSeparator: \.isWhitespace).count, "text": text,
				])
				return text
			}
			return client
		}

		private func pasteboardClient() -> PasteboardClient {
			PasteboardClient(
				paste: { [self] text in
					pasted.withValue { $0.append(text) }
					log.emit("paste", ["text": text])
				},
				copy: { [self] text in
					copied.withValue { $0.append(text) }
					log.emit("copy", ["text": text])
				},
				sendKeyboardCommand: { [self] _ in log.emit("keyboardCommand") }
			)
		}

		private func soundClient() -> SoundEffectsClient {
			SoundEffectsClient(
				play: { [self] sound in log.emit("sound", ["name": sound.rawValue]) },
				stop: { _ in },
				stopAll: {},
				preloadSounds: {},
				setEnabled: { _ in }
			)
		}

		private func notesClient() -> NotesClient {
			var client = NotesClient()
			client.start = { [self] in
				let id = try await engine.start(microphone: false)
				feed.start(into: engine)
				log.emit("notes.start", ["session": id])
				return id
			}
			client.stop = { [self] in
				feed.cancel()
				await engine.stop()
				log.emit("notes.stop")
			}
			client.discard = { [self] in
				feed.cancel()
				await engine.discard()
				log.emit("notes.discard")
			}
			client.events = { [engine] in engine.events.subscribe() }
			client.meters = { [engine] in engine.meters.subscribe() }
			client.resumeUnfinished = {}
			client.list = { [engine] in await engine.list() }
			client.content = { [engine] in await engine.content($0) }
			return client
		}
	}

	// MARK: - Pieces

	private final class Locked<Value>: @unchecked Sendable {
		private let lock = NSLock()
		private var stored: Value
		init(_ value: Value) { stored = value }
		var value: Value {
			get { lock.withLock { stored } }
			set { lock.withLock { stored = newValue } }
		}
		func withValue<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&stored) } }
	}

	private final class EventLog: @unchecked Sendable {
		private let start = ContinuousClock.now
		private let lock = NSLock()

		static func seconds(_ duration: Duration) -> Double {
			Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
		}

		func emit(_ event: String, _ fields: [String: Any] = [:]) {
			var line = fields
			line["event"] = event
			line["t"] = (Self.seconds(ContinuousClock.now - start) * 1000).rounded() / 1000
			let text = json(line)
			lock.withLock { print(text) }
		}
	}

	/// Delivers key events to the handlers `TranscriptionFeature` registers, as the event tap would.
	private final class FakeKeyMonitor: @unchecked Sendable {
		private let lock = NSLock()
		private var keyHandlers: [UUID: @Sendable (KeyEvent) -> Bool] = [:]
		private var inputHandlers: [UUID: @Sendable (InputEvent) -> Bool] = [:]

		/// The hotkey effect (an input handler) and the mode cycler and sent-edit effects (key handlers).
		var isReady: Bool { lock.withLock { !inputHandlers.isEmpty && keyHandlers.count >= 2 } }

		var client: KeyEventMonitorClient {
			var client = KeyEventMonitorClient()
			client.handleKeyEvent = { [self] handler in
				let id = UUID()
				lock.withLock { keyHandlers[id] = handler }
				return KeyEventMonitorToken(cancel: { [self] in lock.withLock { keyHandlers[id] = nil } })
			}
			client.handleInputEvent = { [self] handler in
				let id = UUID()
				lock.withLock { inputHandlers[id] = handler }
				return KeyEventMonitorToken(cancel: { [self] in lock.withLock { inputHandlers[id] = nil } })
			}
			return client
		}

		func send(_ event: KeyEvent) {
			let (key, input) = lock.withLock { (Array(keyHandlers.values), Array(inputHandlers.values)) }
			for handler in key { _ = handler(event) }
			for handler in input { _ = handler(.keyboard(event)) }
		}
	}

	/// Cuts the time a key was held out of the recording, a running offset, as 16 kHz mono WAV files.
	private final class ExcerptSource: @unchecked Sendable {
		private let url: URL
		private let directory: URL
		private let lock = NSLock()
		private var cursor: Double
		private var count = 0

		init(url: URL, offset: Double) {
			self.url = url
			cursor = offset
			directory = FileManager.default.temporaryDirectory.appending(component: "lsnotes-taps-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
			try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		}

		func next(seconds: Double) throws -> (url: URL, start: Double, length: Double) {
			let (start, index) = lock.withLock { () -> (Double, Int) in
				defer { count += 1; cursor += seconds }
				return (cursor, count)
			}
			let file = try AVAudioFile(forReading: url)
			let rate = file.processingFormat.sampleRate
			file.framePosition = AVAudioFramePosition(start * rate)
			let frames = AVAudioFrameCount(min(Int64(seconds * rate), file.length - file.framePosition))
			guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
				throw HarnessError("the file has no audio at \(start) s")
			}
			try file.read(into: buffer, frameCount: frames)
			let out = directory.appending(component: "dictation-\(index).wav")
			let output = try AVAudioFile(
				forWriting: out,
				settings: [
					AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
					AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
				],
				commonFormat: .pcmFormatFloat32, interleaved: false
			)
			try output.write(from: buffer)
			return (out, start, Double(frames) / rate)
		}

		func cleanup() {
			try? FileManager.default.removeItem(at: directory)
		}

		/// The reducer deletes a dictation's audio once it is stored, so the reference pass reads a copy.
		func keepCopy(of audio: URL) -> URL? {
			let copy = directory.appending(component: "kept-\(UUID().uuidString).wav")
			return (try? FileManager.default.copyItem(at: audio, to: copy)) == nil ? nil : copy
		}
	}

	/// Streams the recording into a Notes session at `speed` times real time, from `offset`.
	private final class NotesFeed: @unchecked Sendable {
		private let url: URL
		private let offset: Double
		private let speed: Double
		private let lock = NSLock()
		private var task: Task<Void, Never>?

		init(url: URL, offset: Double, speed: Double) {
			self.url = url
			self.offset = offset
			self.speed = speed
		}

		func start(into engine: NotesEngine) {
			let (url, offset, speed) = (url, offset, speed)
			let task = Task.detached {
				guard let file = try? AVAudioFile(forReading: url),
				      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000)
				else { return }
				file.framePosition = AVAudioFramePosition(offset * 16_000)
				let began = ContinuousClock.now
				var seconds = 0.0
				while !Task.isCancelled, file.framePosition < file.length {
					do { try file.read(into: buffer, frameCount: 16_000) } catch { return }
					await engine.ingest(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
					seconds += 1
					try? await Task.sleep(until: began + .seconds(seconds / speed), clock: .continuous)
				}
			}
			lock.withLock { self.task = task }
		}

		func cancel() {
			lock.withLock { task?.cancel(); task = nil }
		}
	}

	private static func json(_ object: [String: Any]) -> String {
		let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
		return String(decoding: data, as: UTF8.self)
	}

	private struct HarnessError: LocalizedError {
		var errorDescription: String?
		init(_ message: String) { errorDescription = message }
	}
}
#endif
