import Foundation
@testable import HexCore
import Testing

struct ModelFitTests {
	let gib: UInt64 = 1_073_741_824

	@Test
	func fitsWhenMemoryAndDiskAreEnough() {
		let verdict = ModelFit.check(requiredMemoryGB: 16, downloadBytes: 1_400_000_000, physicalMemoryBytes: 16 * gib, freeDiskBytes: 50_000_000_000)
		#expect(verdict == .fits)
	}

	@Test
	func tooLittleMemoryNamesBothNumbers() {
		let verdict = ModelFit.check(requiredMemoryGB: 16, downloadBytes: 1_400_000_000, physicalMemoryBytes: 8 * gib, freeDiskBytes: 50_000_000_000)
		#expect(verdict == .wontFit(reason: "Needs 16 GB of memory; this Mac has 8 GB."))
	}

	@Test
	func tooLittleDiskIncludesTheMargin() {
		// 1.4 GB + 10% = 1.54 GB, shown rounded up; 1.29 GB left, shown rounded down.
		let verdict = ModelFit.check(requiredMemoryGB: nil, downloadBytes: 1_400_000_000, physicalMemoryBytes: 8 * gib, freeDiskBytes: 1_290_000_000)
		#expect(verdict == .wontFit(reason: "Needs 1.6 GB free; 1.2 GB left."))
	}

	@Test
	func diskExactlyAtTheMarginFits() {
		let verdict = ModelFit.check(requiredMemoryGB: nil, downloadBytes: 1_000_000_000, physicalMemoryBytes: 8 * gib, freeDiskBytes: 1_100_000_000)
		#expect(verdict == .fits)
		let short = ModelFit.check(requiredMemoryGB: nil, downloadBytes: 1_000_000_000, physicalMemoryBytes: 8 * gib, freeDiskBytes: 1_099_999_999)
		#expect(short.reason != nil)
	}

	@Test
	func memoryIsReportedBeforeDisk() {
		let verdict = ModelFit.check(requiredMemoryGB: 24, downloadBytes: 4_600_000_000, physicalMemoryBytes: 8 * gib, freeDiskBytes: 100_000_000)
		#expect(verdict.reason == "Needs 24 GB of memory; this Mac has 8 GB.")
	}

	@Test
	func smallSizesAreShownInMegabytes() {
		let verdict = ModelFit.check(requiredMemoryGB: nil, downloadBytes: 650_000_000, physicalMemoryBytes: 8 * gib, freeDiskBytes: 400_000_000)
		#expect(verdict == .wontFit(reason: "Needs 715 MB free; 400 MB left."))
	}

	@Test
	func unknownRequirementsAreSkipped() {
		#expect(ModelFit.check(requiredMemoryGB: nil, downloadBytes: nil, physicalMemoryBytes: 8 * gib, freeDiskBytes: 0) == .fits)
		// Disk unreadable: don't block on a number we don't have.
		#expect(ModelFit.check(requiredMemoryGB: nil, downloadBytes: 1_000_000_000, physicalMemoryBytes: 8 * gib, freeDiskBytes: nil) == .fits)
	}

	@Test
	func parsesModelSizes() {
		#expect(ModelFit.parseSize("1.4GB") == 1_400_000_000)
		#expect(ModelFit.parseSize("2.3 GB") == 2_300_000_000)
		#expect(ModelFit.parseSize("650MB") == 650_000_000)
		#expect(ModelFit.parseSize("macOS") == nil)
	}

	@Test
	func memoryRoundsToWholeGigabytes() {
		#expect(ModelFit.memoryGB(16 * gib) == 16)
		#expect(ModelFit.memoryGB(UInt64(7.9 * Double(gib))) == 8)
	}

	@Test
	func onDeviceModelsMatchTheirCopy() {
		#expect(LocalLLMModel.small.minimumMemoryGB == 8)
		#expect(LocalLLMModel.balanced.minimumMemoryGB == 16)
		#expect(LocalLLMModel.large.minimumMemoryGB == 24)
		#expect(LocalLLMModel.small.fit(physicalMemoryBytes: 8 * gib, freeDiskBytes: 10_000_000_000) == .fits)
		#expect(LocalLLMModel.large.fit(physicalMemoryBytes: 8 * gib, freeDiskBytes: 10_000_000_000).reason == "Needs 24 GB of memory; this Mac has 8 GB.")
		#expect(LocalLLMModel.balanced.fit(physicalMemoryBytes: 16 * gib, freeDiskBytes: 2_000_000_000).reason == "Needs 2.6 GB free; 2.0 GB left.")
	}
}
