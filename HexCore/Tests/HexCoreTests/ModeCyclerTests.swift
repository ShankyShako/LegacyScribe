@testable import HexCore
import Sauce
import Testing

struct ModeCyclerTests {
	private func feed(_ cycler: inout ModeCycler, _ events: [KeyEvent], current: RewriteMode = .clean) -> [ModeCycler.Output] {
		events.compactMap { cycler.handle($0, currentMode: current) }
	}

	private let none = KeyEvent(key: nil, modifiers: [])
	private let ctrl = KeyEvent(key: nil, modifiers: [.control])
	private let ctrlOpt = KeyEvent(key: nil, modifiers: [.control, .option.with(side: .right)])
	private let opt = KeyEvent(key: nil, modifiers: [.option])

	@Test
	func controlThenOptionPicksTheNextModeAndReleaseCommits() {
		var cycler = ModeCycler()
		#expect(feed(&cycler, [ctrl, ctrlOpt, ctrl, none]) == [
			.began(highlight: .prompt), .optionReleased, .committed(.prompt),
		])
	}

	@Test
	func eachOptionPressAdvancesAndWraps() {
		var cycler = ModeCycler()
		#expect(feed(&cycler, [ctrl, ctrlOpt, ctrl, ctrlOpt, ctrl, ctrlOpt, none]) == [
			.began(highlight: .prompt), .optionReleased,
			.advanced(highlight: .raw), .optionReleased,
			.advanced(highlight: .clean), .committed(.clean),
		])
	}

	@Test
	func holdingOptionAdvancesOnTheCallersTimer() {
		var cycler = ModeCycler()
		_ = feed(&cycler, [ctrl, ctrlOpt])
		#expect(cycler.advance() == .raw)
		#expect(cycler.advance() == .clean)
		#expect(feed(&cycler, [ctrl]) == [.optionReleased])
		#expect(cycler.advance() == nil)
		#expect(feed(&cycler, [none]) == [.committed(.clean)])
		#expect(cycler.advance() == nil)
	}

	@Test
	func anotherKeyAborts() {
		var cycler = ModeCycler()
		let digit = KeyEvent(key: .one, modifiers: [.control, .option])
		#expect(feed(&cycler, [ctrl, ctrlOpt, digit, ctrlOpt, none]) == [.began(highlight: .prompt), .aborted])
	}

	@Test
	func anExtraModifierAborts() {
		var cycler = ModeCycler()
		let withShift = KeyEvent(key: nil, modifiers: [.control, .option, .shift])
		#expect(feed(&cycler, [ctrl, ctrlOpt, withShift, ctrl, none]) == [.began(highlight: .prompt), .aborted])
	}

	@Test
	func optionFirstNeverStartsTheBar() {
		var cycler = ModeCycler()
		let rightOption = KeyEvent(key: nil, modifiers: [.option.with(side: .right)])
		#expect(feed(&cycler, [rightOption, ctrlOpt, ctrl, none]).isEmpty)
	}

	@Test
	func controlTapsWhileHoldingTheTalkKeyStepModes() {
		var cycler = ModeCycler()
		let rightOption = KeyEvent(key: nil, modifiers: [.option.with(side: .right)])
		#expect(feed(&cycler, [rightOption, ctrlOpt, rightOption], current: .clean) == [.stepped(.prompt)])
		#expect(feed(&cycler, [ctrlOpt, rightOption, none], current: .prompt) == [.stepped(.raw)])
	}

	@Test
	func aChordWhileHoldingOptionDoesNotStep() {
		var cycler = ModeCycler()
		let withKey = KeyEvent(key: .x, modifiers: [.control, .option])
		#expect(feed(&cycler, [opt, ctrlOpt, withKey, opt, none]).isEmpty)
	}

	@Test
	func controlShortcutsNeverStartACycle() {
		var cycler = ModeCycler()
		let ctrlC = KeyEvent(key: .c, modifiers: [.control])
		#expect(feed(&cycler, [ctrl, ctrlC, ctrlOpt, ctrl, none]).isEmpty)
		// A clean press afterwards still works.
		#expect(feed(&cycler, [ctrl, ctrlOpt, none]) == [.began(highlight: .prompt), .committed(.prompt)])
	}

	@Test
	func firstPickFollowsTheCurrentMode() {
		var cycler = ModeCycler()
		#expect(feed(&cycler, [ctrl, ctrlOpt], current: .prompt) == [.began(highlight: .raw)])
	}
}
