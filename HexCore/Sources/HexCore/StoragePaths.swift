import Foundation

public extension URL {
	static var hexApplicationSupport: URL {
		get throws {
			let fm = FileManager.default
			#if DEBUG
			// Test harnesses (the notes crash test) run against a scratch data root.
			if let root = ProcessInfo.processInfo.environment["LEGACYSCRIBE_DATA_ROOT"], !root.isEmpty {
				let url = URL(fileURLWithPath: root, isDirectory: true)
				try fm.createDirectory(at: url, withIntermediateDirectories: true)
				return url
			}
			#endif
			let appSupport = try fm.url(
				for: .applicationSupportDirectory,
				in: .userDomainMask,
				appropriateFor: nil,
				create: true
			)
			let hexDirectory = appSupport.appendingPathComponent("LegacyScribe", isDirectory: true)
			try fm.createDirectory(at: hexDirectory, withIntermediateDirectories: true)
			return hexDirectory
		}
	}

	static var legacyDocumentsDirectory: URL {
		FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
	}

	static func hexMigratedFileURL(named fileName: String) -> URL {
		let newURL = (try? hexApplicationSupport.appending(component: fileName))
			?? documentsDirectory.appending(component: fileName)
		let legacyURL = legacyDocumentsDirectory.appending(component: fileName)
		FileManager.default.migrateIfNeeded(from: legacyURL, to: newURL)
		return newURL
	}

	static var hexModelsDirectory: URL {
		get throws {
			let modelsDirectory = try hexApplicationSupport.appendingPathComponent("Models/whisperkit", isDirectory: true)
			try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
			return modelsDirectory
		}
	}

	/// Root for FluidAudio (Parakeet) models. FluidAudio places each model in a
	/// `<root>/<repo-folder>` sibling of whatever directory it is handed, so the app and
	/// `tools/lsbench` share downloads as long as they use this root.
	static var hexParakeetModelsDirectory: URL {
		get throws {
			let dir = try hexApplicationSupport.appendingPathComponent("Models/fluidaudio", isDirectory: true)
			try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
			return dir
		}
	}

	/// Root for MLX checkpoints, laid out as `<root>/<hf-owner>/<hf-repo>` (shared with `tools/lsbench`).
	static var hexMLXModelsDirectory: URL {
		get throws {
			let dir = try hexApplicationSupport.appendingPathComponent("Models/mlx", isDirectory: true)
			try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
			return dir
		}
	}
}

public extension FileManager {
	func migrateIfNeeded(from legacy: URL, to new: URL) {
		guard fileExists(atPath: legacy.path), !fileExists(atPath: new.path) else { return }
		try? copyItem(at: legacy, to: new)
	}

	func removeItemIfExists(at url: URL) {
		guard fileExists(atPath: url.path) else { return }
		try? removeItem(at: url)
	}
}
