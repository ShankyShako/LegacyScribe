import Foundation

/// Whether a model can be downloaded and run on this Mac: enough memory to load it, enough free
/// disk to hold it. Pure; the app reads the Mac's numbers (`MachineProbe`) and passes them in.
public enum ModelFit {
	/// Disk kept free on top of the download itself (partial files, unpacking, the system's own use).
	public static let diskMarginPercent: Int64 = 10

	public enum Verdict: Equatable, Sendable {
		case fits
		/// `reason` is a full sentence for the row's info popover and `.help()`.
		case wontFit(reason: String)

		public var reason: String? {
			if case let .wontFit(reason) = self { return reason }
			return nil
		}
	}

	/// Memory is checked first: a Mac that is too small for a model can't be fixed by deleting files.
	/// A nil requirement (no figure known, or a system-hosted model) skips that check.
	public static func check(
		requiredMemoryGB: Int?,
		downloadBytes: Int64?,
		physicalMemoryBytes: UInt64,
		freeDiskBytes: Int64?
	) -> Verdict {
		if let requiredMemoryGB, memoryGB(physicalMemoryBytes) < requiredMemoryGB {
			return .wontFit(reason: "Needs \(requiredMemoryGB) GB of memory; this Mac has \(memoryGB(physicalMemoryBytes)) GB.")
		}
		if let downloadBytes, let freeDiskBytes {
			let needed = (downloadBytes * (100 + diskMarginPercent) + 99) / 100
			if freeDiskBytes < needed {
				return .wontFit(reason: "Needs \(sizeText(needed, rounding: .up)) free; \(sizeText(max(freeDiskBytes, 0), rounding: .down)) left.")
			}
		}
		return .fits
	}

	/// Whole GB of RAM as macOS sells it (a "16 GB" Mac reports 16 GiB).
	public static func memoryGB(_ bytes: UInt64) -> Int {
		Int((Double(bytes) / 1_073_741_824).rounded())
	}

	/// "1.4GB", "1.4 GB", "650MB" → bytes (decimal, as Finder and the download pages count). Nil for anything else.
	public static func parseSize(_ text: String) -> Int64? {
		let scanner = Scanner(string: text.trimmingCharacters(in: .whitespaces))
		guard let value = scanner.scanDouble() else { return nil }
		let unit = scanner.scanCharacters(from: .letters)?.uppercased()
		switch unit {
		case "GB": return Int64(value * 1_000_000_000)
		case "MB": return Int64(value * 1_000_000)
		default: return nil
		}
	}

	/// Decimal GB with one digit, or whole MB below 1 GB. Rounds the way that keeps the sentence true:
	/// the need up, the space left down.
	static func sizeText(_ bytes: Int64, rounding: FloatingPointRoundingRule) -> String {
		if bytes >= 1_000_000_000 {
			let tenths = (Double(bytes) / 100_000_000).rounded(rounding)
			return String(format: "%.1f GB", tenths / 10)
		}
		let megabytes = (Double(bytes) / 1_000_000).rounded(rounding)
		return "\(Int(megabytes)) MB"
	}
}

extension LocalLLMModel {
	/// Physical memory the Mac needs for this model: the figures already in `summary`, which sit
	/// above the measured peaks (docs/bench-results.md: 1.7B 2.2 GB, 4B 3.7 GB, app included).
	public var minimumMemoryGB: Int {
		switch self {
		case .small: 8
		case .balanced: 16
		case .large: 24
		}
	}

	public var downloadBytes: Int64? { ModelFit.parseSize(downloadSize) }

	public func fit(physicalMemoryBytes: UInt64, freeDiskBytes: Int64?) -> ModelFit.Verdict {
		ModelFit.check(
			requiredMemoryGB: minimumMemoryGB,
			downloadBytes: downloadBytes,
			physicalMemoryBytes: physicalMemoryBytes,
			freeDiskBytes: freeDiskBytes
		)
	}
}
