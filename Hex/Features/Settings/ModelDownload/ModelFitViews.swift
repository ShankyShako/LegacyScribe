import HexCore
import SwiftUI

/// This Mac's memory and free disk, read when a model list appears (not on every redraw).
struct MachineProbe: Equatable {
	var physicalMemoryBytes: UInt64
	/// Space the data root's volume can give a download, counting what macOS would purge.
	/// Nil when it can't be read, which never blocks a download.
	var freeDiskBytes: Int64?

	static func current() -> MachineProbe {
		let root = (try? URL.hexApplicationSupport) ?? URL(fileURLWithPath: NSHomeDirectory())
		let free = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
		return MachineProbe(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, freeDiskBytes: free)
	}
}

extension CuratedModelInfo {
	/// A model already on disk stays usable whatever the numbers say; only a download is checked.
	func fit(on machine: MachineProbe?) -> ModelFit.Verdict {
		guard let machine, !isDownloaded else { return .fits }
		return ModelFit.check(
			requiredMemoryGB: minMemoryGB,
			downloadBytes: ModelFit.parseSize(storageSize),
			physicalMemoryBytes: machine.physicalMemoryBytes,
			freeDiskBytes: machine.freeDiskBytes
		)
	}
}

extension LocalLLMModel {
	func fit(on machine: MachineProbe?) -> ModelFit.Verdict {
		guard let machine else { return .fits }
		return fit(physicalMemoryBytes: machine.physicalMemoryBytes, freeDiskBytes: machine.freeDiskBytes)
	}
}

/// Orange "Won't fit" capsule that sits after a model's name.
struct WontFitBadge: View {
	var body: some View {
		Text("Won't fit")
			.font(.caption2.weight(.medium))
			.foregroundStyle(Color.orange)
			.padding(.horizontal, 6)
			.padding(.vertical, 2)
			.background(Color.orange.opacity(0.15), in: Capsule())
	}
}

/// Info icon whose popover (on click) and tooltip give the reason a model won't fit.
struct WontFitInfoButton: View {
	let reason: String
	@State private var isShown = false

	var body: some View {
		Button {
			isShown.toggle()
		} label: {
			Image(systemName: "info.circle")
				.foregroundStyle(.secondary)
		}
		.buttonStyle(.plain)
		.help(reason)
		.accessibilityLabel("Why this model won't fit")
		.accessibilityHint(reason)
		.popover(isPresented: $isShown, arrowEdge: .bottom) {
			Text(reason)
				.font(.callout)
				.fixedSize(horizontal: false, vertical: true)
				.frame(maxWidth: 240, alignment: .leading)
				.padding(12)
		}
	}
}
