import XCTest
@testable import Kioku

// Characterizes FuriganaAttributedString's run detection and reading projection for two cases the
// Read tab got wrong: a number + counter (the reading must span the digits too) and a surface
// whose okurigana repeats the first run's own reading (言い訳).
@MainActor
final class FuriganaRunTests: XCTestCase {

    // Digits beside a kanji join its run; digits alone are not a run.
    func testDigitsJoinAKanjiRun() {
        XCTAssertEqual(FuriganaAttributedString.kanjiRuns(in: "２人").map { [$0.start, $0.end] }, [[0, 2]])
        XCTAssertEqual(FuriganaAttributedString.kanjiRuns(in: "3回目").map { [$0.start, $0.end] }, [[0, 3]])
        XCTAssertEqual(FuriganaAttributedString.kanjiRuns(in: "2024").count, 0)
        XCTAssertEqual(FuriganaAttributedString.kanjiRuns(in: "二人").map { [$0.start, $0.end] }, [[0, 2]])
    }

    // A number + counter reading covers the whole run.
    func testNumberCounterReadingCoversTheDigits() {
        XCTAssertEqual(FuriganaAttributedString.projectRunReadings(surface: "２人", reading: "ふたり"), ["ふたり"])
    }

    // 言い訳: each run keeps at least one kana, so 言 gets い and 訳 gets わけ.
    func testOkuriganaMatchingTheRunsOwnReadingSplitsCorrectly() {
        XCTAssertEqual(FuriganaAttributedString.projectRunReadings(surface: "言い訳", reading: "いいわけ"), ["い", "わけ"])
        XCTAssertEqual(FuriganaAttributedString.projectRunReadings(surface: "振り子", reading: "ふりこ"), ["ふ", "こ"])
    }
}
