import Testing
@testable import HexCore

struct InsertionAdjusterTests {
	func adjust(_ text: String, _ before: String, _ after: String = "", keep: [String] = []) -> String {
		InsertionAdjuster.adjust(text, before: before, after: after, keepCapitalized: keep)
	}

	@Test
	func emptyFieldLeavesTextAlone() {
		#expect(adjust("Hello there.", "") == "Hello there.")
	}

	@Test
	func lowercasesMidSentence() {
		#expect(adjust("The report is ready.", "I think ") == "the report is ready.")
		#expect(adjust("The report is ready.", "I think,") == " the report is ready.")
	}

	@Test
	func keepsCapitalAfterSentenceEnd() {
		#expect(adjust("The report is ready.", "Done. ") == "The report is ready.")
		#expect(adjust("The report is ready.", "Done!") == " The report is ready.")
		#expect(adjust("The report is ready.", "He said \"done.\" ") == "The report is ready.")
		#expect(adjust("The report is ready.", "Status: ") == "The report is ready.")
		#expect(adjust("The report is ready.", "Notes\n") == "The report is ready.")
		#expect(adjust("The report is ready.", "Notes\n  ") == "The report is ready.")
	}

	@Test
	func listMarkersStartASentence() {
		#expect(adjust("Buy milk.", "Shopping\n- ") == "Buy milk.")
		#expect(adjust("Buy milk.", "Shopping\n2. ") == "Buy milk.")
		#expect(adjust("Buy milk.", "Shopping\n* ") == "Buy milk.")
	}

	@Test
	func keepsIAcronymsAndInnerCapitals() {
		#expect(adjust("I think so.", "well ") == "I think so.")
		#expect(adjust("I'm sure.", "well ") == "I'm sure.")
		#expect(adjust("I’ll check.", "well ") == "I’ll check.")
		#expect(adjust("NASA launched it.", "then ") == "NASA launched it.")
		#expect(adjust("GitHub is down.", "and ") == "GitHub is down.")
	}

	@Test
	func keepsKnownSpellings() {
		#expect(adjust("Cohere is faster.", "and ", keep: ["Cohere"]) == "Cohere is faster.")
		#expect(adjust("Claude Code wrote it.", "and ", keep: ["Claude Code"]) == "Claude Code wrote it.")
		// A known spelling only protects the whole first word.
		#expect(adjust("Coherent output.", "and ", keep: ["Cohere"]) == "coherent output.")
	}

	@Test
	func keepsNamesWeekdaysAndMonths() {
		#expect(adjust("John said he would come.", "and ") == "John said he would come.")
		#expect(adjust("Microsoft shipped it.", "and ") == "Microsoft shipped it.")
		#expect(adjust("Monday works.", "and ") == "Monday works.")
	}

	@Test
	func dropsPeriodWhenTheSentenceContinues() {
		#expect(adjust("The report is ready.", "I think ", " and we can ship") == "the report is ready")
		#expect(adjust("The report is ready.", "I think ", "and we can ship") == "the report is ready ")
		#expect(adjust("The report is ready.", "I think ", ", so ship it") == "the report is ready")
		#expect(adjust("The report is ready.", "I think ", ".") == "the report is ready")
	}

	@Test
	func keepsPeriodBeforeANewSentence() {
		#expect(adjust("The report is ready.", "I think ", " We can ship.") == "the report is ready.")
		#expect(adjust("The report is ready.", "I think ", "\nWe can ship.") == "the report is ready.")
	}

	@Test
	func keepsEllipsesAbbreviationsAndOtherMarks() {
		#expect(adjust("Wait for it...", "and ", " then go") == "wait for it...")
		#expect(adjust("Apples, pears, etc.", "buy ", " and so on") == "apples, pears, etc.")
		#expect(adjust("Use a tool, e.g.", "so ", " a hammer") == "use a tool, e.g.")
		#expect(adjust("Is it ready?", "so ", " and when") == "is it ready?")
	}

	@Test
	func addsSpacesWhereWordsMeet() {
		#expect(adjust("Ready.", "Done.") == " Ready.")
		#expect(adjust("ready", "is it", "now") == " ready ")
		#expect(adjust("Ready.", "Done.", "Next") == " Ready. ")
		#expect(adjust("Ready.", "see (") == "ready.")
		#expect(adjust("Ready.", "foo ", " bar") == "ready")
	}

	@Test
	func noSpaceBeforeLeadingPunctuation() {
		#expect(adjust(", and more.", "apples") == ", and more.")
	}

	@Test
	func multilineTextOnlyGetsSpacing() {
		let prompt = "Goal\n- Fix the bug."
		#expect(adjust(prompt, "see ", " and then") == prompt)
		#expect(adjust(prompt, "see", "") == " " + prompt)
	}
}
