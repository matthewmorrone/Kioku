import XCTest
@testable import Kioku

// Covers the compact change list behind the long-press on the Read tab's segment-list button:
// boundary changes as `default → current` with `|` between segments, reading changes as
// `A(B) → A(C)`, in text order.
final class SegmentationChangeListTests: XCTestCase {

    // Builds edges for `text` cut into the given pieces, in order.
    private func edges(_ text: String, _ pieces: [String]) -> [LatticeEdge] {
        var start = text.startIndex
        return pieces.map { piece in
            let end = text.index(start, offsetBy: piece.count)
            defer { start = end }
            return LatticeEdge(start: start, end: end, surface: piece)
        }
    }

    // A merge is listed default-first; the merged word's changed reading is its own line.
    func testMergeAndReadingChange() {
        let text = "映画の様に"
        let lines = SegmentationChangeList.lines(
            text: text,
            defaultEdges: edges(text, ["映画", "の", "様", "に"]),
            currentEdges: edges(text, ["映画", "の様に"]),
            defaultFurigana: (byLocation: [0: "えいが", 3: "さま"], lengthByLocation: [0: 2, 3: 1]),
            currentFurigana: (byLocation: [0: "えいが", 3: "よう"], lengthByLocation: [0: 2, 3: 1])
        )
        XCTAssertEqual(lines, ["の|様|に → の様に", "の様に(のさまに) → の様に(のように)"])
    }

    // A split is listed the other way round, and an unchanged note lists nothing.
    func testSplitAndNoChange() {
        let text = "月色"
        let split = SegmentationChangeList.lines(
            text: text,
            defaultEdges: edges(text, ["月色"]),
            currentEdges: edges(text, ["月", "色"]),
            defaultFurigana: (byLocation: [0: "つき", 1: "いろ"], lengthByLocation: [0: 1, 1: 1]),
            currentFurigana: (byLocation: [0: "つき", 1: "いろ"], lengthByLocation: [0: 1, 1: 1])
        )
        XCTAssertEqual(split, ["月色 → 月|色"])

        let unchanged = SegmentationChangeList.lines(
            text: text,
            defaultEdges: edges(text, ["月色"]),
            currentEdges: edges(text, ["月色"]),
            defaultFurigana: (byLocation: [0: "つきいろ"], lengthByLocation: [0: 2]),
            currentFurigana: (byLocation: [0: "つきいろ"], lengthByLocation: [0: 2])
        )
        XCTAssertEqual(unchanged, [])
    }

    // The same change made at several places is listed once.
    func testRepeatedChangeListedOnce() {
        let text = "の様にの様に"
        let lines = SegmentationChangeList.lines(
            text: text,
            defaultEdges: edges(text, ["の", "様", "に", "の", "様", "に"]),
            currentEdges: edges(text, ["の様に", "の様に"]),
            defaultFurigana: (byLocation: [1: "よう", 4: "よう"], lengthByLocation: [1: 1, 4: 1]),
            currentFurigana: (byLocation: [1: "よう", 4: "よう"], lengthByLocation: [1: 1, 4: 1])
        )
        XCTAssertEqual(lines, ["の|様|に → の様に"])
    }
}
