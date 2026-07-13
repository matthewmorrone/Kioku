import XCTest
@testable import Kioku

// Verifies the pure coverage aggregation: grouping saved words into a JLPT-level × mastery-stage
// grid, ordering levels easiest→hardest then No-level, and computing totals / coverage % / due count.
@MainActor
final class NoteCoverageCalculatorTests: XCTestCase {

    // Five words across two JLPT levels + a no-level word, with mixed stages and one due word.
    func testGroupsByLevelAndStageWithTotals() {
        let words = (1...5).map { SavedWord(canonicalEntryID: Int64($0), surface: "w\($0)") }
        let level: (Int64) -> Int? = { id in
            switch id {
            case 1, 2: return 5   // N5
            case 3, 5: return 4   // N4
            default:   return nil // No level
            }
        }
        let stage: (Int64) -> MasteryStage = { id in
            switch id {
            case 1, 5: return .learned
            case 3:    return .learning
            default:   return .new
            }
        }
        let isDue: (Int64) -> Bool = { $0 == 5 }

        let cov = NoteCoverageCalculator.compute(words: words, level: level, stage: stage, isDue: isDue)

        XCTAssertEqual(cov.total, 5)
        XCTAssertEqual(cov.learnedCount, 2)
        XCTAssertEqual(cov.dueCount, 1)
        XCTAssertEqual(cov.coverageFraction, 0.4, accuracy: 0.0001)
        // Levels ordered N5 (5) → N4 (4) → No level (nil).
        XCTAssertEqual(cov.levels.map(\.level), [5, 4, nil])
        let n5 = cov.levels[0]
        XCTAssertEqual(n5.total, 2)
        XCTAssertEqual(n5.learnedCount, 1)
        XCTAssertEqual(n5.words(in: .learned).map(\.canonicalEntryID), [1])
        XCTAssertEqual(n5.words(in: .new).map(\.canonicalEntryID), [2])
    }

    // An empty note has zero coverage and no level rows (no divide-by-zero).
    func testEmptyNoteHasZeroCoverage() {
        let cov = NoteCoverageCalculator.compute(
            words: [], level: { _ in nil }, stage: { _ in .new }, isDue: { _ in false }
        )
        XCTAssertEqual(cov.total, 0)
        XCTAssertEqual(cov.learnedCount, 0)
        XCTAssertEqual(cov.coverageFraction, 0)
        XCTAssertTrue(cov.levels.isEmpty)
    }
}
