import XCTest
@testable import Kioku

// Guards tap → segment resolution for the CoreText Read path. Mis-resolution silently
// breaks tap-to-look-up (the most-used Read interaction) without a crash or visible
// regression, so it deserves explicit coverage.
@MainActor
final class KiokuCoreTextSegmentResolverTests: XCTestCase {

    func test_emptyRanges_returnsNil() {
        XCTAssertNil(KiokuCoreTextSegmentResolver.segmentRange(forCharacterIndex: 0, in: []))
    }

    func test_indexInsideRange_returnsContainingRange() {
        let ranges = [
            NSRange(location: 0, length: 3),
            NSRange(location: 3, length: 2),
        ]
        let match = KiokuCoreTextSegmentResolver.segmentRange(forCharacterIndex: 1, in: ranges)
        XCTAssertEqual(match, NSRange(location: 0, length: 3))
    }

    func test_indexAtRangeStart_returnsRange() {
        let ranges = [NSRange(location: 5, length: 4)]
        let match = KiokuCoreTextSegmentResolver.segmentRange(forCharacterIndex: 5, in: ranges)
        XCTAssertEqual(match, NSRange(location: 5, length: 4))
    }

    func test_indexAtRangeEnd_returnsNil() {
        // NSLocationInRange treats the end as exclusive (location + length is past the last
        // index in the range). Tap exactly at the boundary should fall into the next segment
        // if any, otherwise no match.
        let ranges = [NSRange(location: 0, length: 3)]
        XCTAssertNil(KiokuCoreTextSegmentResolver.segmentRange(forCharacterIndex: 3, in: ranges))
    }

    func test_indexAtRangeEnd_fallsIntoAdjacentRange() {
        let ranges = [
            NSRange(location: 0, length: 3),
            NSRange(location: 3, length: 2),
        ]
        let match = KiokuCoreTextSegmentResolver.segmentRange(forCharacterIndex: 3, in: ranges)
        XCTAssertEqual(match, NSRange(location: 3, length: 2))
    }

    func test_indexBeyondLastRange_returnsNil() {
        let ranges = [NSRange(location: 0, length: 3)]
        XCTAssertNil(KiokuCoreTextSegmentResolver.segmentRange(forCharacterIndex: 100, in: ranges))
    }

    func test_negativeIndex_returnsNil() {
        let ranges = [NSRange(location: 0, length: 3)]
        XCTAssertNil(KiokuCoreTextSegmentResolver.segmentRange(forCharacterIndex: -1, in: ranges))
    }

    func test_gapBetweenSegments_returnsNil() {
        // Punctuation between segments produces a gap; taps there should clear selection.
        let ranges = [
            NSRange(location: 0, length: 2),   // "こん"
            NSRange(location: 3, length: 2),   // "ちは"  (gap at index 2 = "、")
        ]
        XCTAssertNil(KiokuCoreTextSegmentResolver.segmentRange(forCharacterIndex: 2, in: ranges))
    }
}
