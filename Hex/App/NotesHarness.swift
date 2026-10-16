#if DEBUG
import AVFoundation
import Foundation
import HexCore

/// Headless notes sessions for `tools/notes-crashtest.sh`: the real `NotesEngine` (Cohere, speech detector,
/// transcript commits, notes writer) fed from a WAV file instead of the microphone. Debug builds only; the
/// data root comes from `LEGACYSCRIBE_DATA_ROOT` so a run never touches the user's sessions.
///
///     "LegacyScribe Debug" --notes-harness record <file.wav> [--speed 20]
///     "LegacyScribe Debug" --notes-harness resume
///     "LegacyScribe Debug" --notes-harness enrol <folder of recordings>
///
/// Prints one JSON object per line: stage changes, each committed chunk with the process footprint, and
/// a final summary. Exits 0 once every session is done, 1 on an error.
enum NotesHarness {
	static var isRequested: Bool {
		CommandLine.arguments.contains("--notes-harness")
	}

	static func runAndExit() -> Never {
		// One event per line, as it happens, even when stdout is a file.
		setvbuf(stdout, nil, _IOLBF, 0)
		Task.detached {
			let code = await run(Array(CommandLine.arguments.drop(while: { $0 != "--notes-harness" }).dropFirst()))
			exit(code)
		}
		RunLoop.main.run()
		exit(0)
	}

	private static func run(_ arguments: [String]) async -> Int32 {
		let engine = NotesEngine()
		do {
			switch arguments.first {
			case "record":
				guard arguments.count >= 2 else { throw HarnessError("record needs a WAV path") }
				let speed = arguments.firstIndex(of: "--speed").flatMap { Double(arguments[$0 + 1]) } ?? 20
				// Streamed a second at a time, so a 2-hour file doesn't sit in memory and skew the footprint.
				let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[1]))
				let format = file.processingFormat
				guard format.sampleRate == 16_000, format.channelCount == 1, format.commonFormat == .pcmFormatFloat32,
				      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)
				else { throw HarnessError("the feed must be a 16 kHz mono WAV") }
				print(json(["event": "loaded", "seconds": Double(file.length) / 16_000]))
				let id = try await engine.start(microphone: false)
				print(json(["event": "started", "session": id]))
				let watcher = Task { await watch(engine) }
				while file.framePosition < file.length {
					try file.read(into: buffer, frameCount: 16_000)
					await engine.ingest(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
					try await Task.sleep(for: .seconds(1 / speed))
				}
				await engine.stop()
				print(json(["event": "stopped", "session": id]))
				await watcher.value
			case "resume":
				await engine.resumeUnfinished()
				await watch(engine)
			case "enrol":
				// The user's voiceprint from a folder of recordings (read only), saved under the data root.
				guard arguments.count >= 2 else { throw HarnessError("enrol needs a folder of recordings") }
				let folder = URL(fileURLWithPath: arguments[1], isDirectory: true)
				let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
					.filter { ["wav", "flac", "m4a", "caf"].contains(($0 as NSString).pathExtension.lowercased()) }
					.sorted()
				let voiceprint = try await engine.enrolVoiceprint(recordings: names.map { folder.appending(component: $0) })
				let norm = voiceprint.embedding.reduce(0) { $0 + $1 * $1 }.squareRoot()
				print(json([
					"event": "enrolled", "sources": voiceprint.sourceCount, "seconds": voiceprint.sourceSeconds,
					"dimensions": voiceprint.embedding.count, "norm": norm, "selfScoreMedian": voiceprint.selfScoreMedian,
				]))
			default:
				throw HarnessError("usage: --notes-harness record <file.wav> [--speed N] | resume | enrol <folder>")
			}
			return 0
		} catch {
			print(json(["event": "error", "message": error.localizedDescription]))
			return 1
		}
	}

	/// Polls the sessions until none is unfinished, printing every change.
	private static func watch(_ engine: NotesEngine) async {
		var last: [String: String] = [:]
		while true {
			let sessions = await engine.list()
			for summary in sessions {
				let state = "\(summary.session.stage.rawValue)/\(summary.transcribedChunks)/\(summary.pendingChunks)/\(summary.progress?.partsDone ?? -1)/\(summary.session.notesError ?? "")"
				guard last[summary.id] != state else { continue }
				last[summary.id] = state
				var line: [String: Any] = [
					"event": "status",
					"session": summary.id,
					"stage": summary.session.stage.rawValue,
					"transcribed": summary.transcribedChunks,
					"pending": summary.pendingChunks,
					"gaps": summary.gaps,
					"speakers": summary.speakerCount,
					"footprint": NotesEngine.footprint(),
				]
				if let progress = summary.progress {
					line["partsDone"] = progress.partsDone
					line["partsTotal"] = progress.partsTotal
				}
				if let error = summary.session.notesError { line["notesError"] = error }
				print(json(line))
			}
			let unfinished = sessions.filter { $0.session.stage != .done && $0.session.notesError == nil }
			if !sessions.isEmpty, unfinished.isEmpty {
				print(json(["event": "finished", "sessions": sessions.map(\.id), "footprint": NotesEngine.footprint()]))
				return
			}
			try? await Task.sleep(for: .milliseconds(200))
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
