import XCTest
@testable import Kioku

// Pins the split editor's scores to the segmentation: Segmenter.splitCosts must price the cut the
// path search actually chose as the cheapest cut of its segment. If a second scorer ever creeps in,
// or splitCosts stops pricing lines the way viterbiSelect does, the two disagree and this fails.
@MainActor
final class SplitCostsTests: XCTestCase {

    // For every pair of adjacent words the segmenter picks, merges them into one segment and checks
    // that no cut of that segment costs less than the segmenter's own cut, in the line's context.
    func testSegmenterCutIsTheCheapestSplit() throws {
        let segmenter = try TestReadResources.shared().segmenter
        let lines = [
            "泣きたくなるようなムーンライト",
            "彼のような人になりたい",
            "列車がなかったので、私たちはずっと歩かなければならなかった。",
            "どこかに行きたい",
        ]
        for line in lines {
            let path = segmenter.viterbiBestPath(for: line)
            XCTAssertFalse(path.isEmpty, "No path for \(line)")
            for (left, right) in zip(path, path.dropFirst()) {
                let range = left.start..<right.end
                let segment = String(line[range])
                let characters = Array(segment)
                let cuts = (1..<characters.count).map { [String(characters[..<$0]), String(characters[$0...])] }
                let costs = segmenter.splitCosts(of: range, in: line, candidates: cuts)
                let chosen = [left.surface, right.surface]
                guard let chosenIndex = cuts.firstIndex(of: chosen), let chosenCost = costs[chosenIndex] else {
                    XCTFail("No cost for the segmenter's own cut \(chosen) in \(line)")
                    continue
                }
                let cheapest = costs.compactMap { $0 }.min()
                XCTAssertEqual(chosenCost, cheapest, "\(line): segmenter cut \(chosen) is not the cheapest of \(zip(cuts, costs).map { "\($0.0.joined(separator: "・"))=\($0.1.map(String.init) ?? "nil")" })")
            }
        }
    }

    // A cut whose piece the dictionary lacks (こかに in ど|こかに) is still priced — as unknown text —
    // so the editor can show every cut, not just the dictionary's.
    func testCutWithUnknownPieceIsPriced() throws {
        let segmenter = try TestReadResources.shared().segmenter
        let line = "どこかに"
        let costs = segmenter.splitCosts(of: line.startIndex..<line.endIndex, in: line, candidates: [["ど", "こかに"], ["どこか", "に"]])
        XCTAssertNotNil(costs[0])
        XCTAssertNotNil(costs[1])
        XCTAssertLessThan(costs[1]!, costs[0]!)
    }
}
