import XCTest
@testable import Kioku

// Characterizes LLMCorrectionClient.completedLineCount, which drives the Read tab's in-progress
// line highlight from a streamed compact-format correction.
@MainActor
final class LLMCorrectionClientTests: XCTestCase {

    // The highest `N|` record seen is the number of lines finished.
    func testCountsHighestNumberedRecord() {
        XCTAssertEqual(LLMCorrectionClient.completedLineCount(in: "1|(朽)[く]ちた|花びら|\n2|(冷)[ひ]んやりと|\n"), 2)
    }

    // Blank-line records count; prose and nothing-yet count as zero.
    func testBlankRecordsAndNoise() {
        XCTAssertEqual(LLMCorrectionClient.completedLineCount(in: "1|a|\n2|\n3|b|\n"), 3)
        XCTAssertEqual(LLMCorrectionClient.completedLineCount(in: "Here is the corrected format:\n"), 0)
        XCTAssertEqual(LLMCorrectionClient.completedLineCount(in: ""), 0)
    }
}
