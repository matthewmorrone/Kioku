import XCTest
@testable import Kioku

// One-off dump of segmentation output for phrases the user flagged as suspicious in
// ムーンライト伝説. Prints the full lattice and the chosen path for both greedy and
// Viterbi modes so we can see exactly where boundaries land — not derived from
// pixel-color inspection of a screenshot.
//
// Not asserting anything — purely diagnostic. `xcrun xcodebuild test ... -only-testing:KiokuTests/SegmentationDumpTests`.
@MainActor
final class SegmentationDumpTests: XCTestCase {

    private let phrases = [
        "今すぐ会いたいよ",
        "ハートは万華鏡",
        "同じ地球に生まれたの",
        // のま vs また bug — expected path: 中 / の / またたく (entry 31593, またたく = "to twinkle")
        "命は闇の中のまたたく光だ",
    ]

    func testDumpGreedy() throws {
        let resources = try TestReadResources.shared()
        UserDefaults.standard.set(false, forKey: SegmenterSettings.viterbiEnabledKey)
        dump(label: "GREEDY", segmenter: resources.segmenter)
    }

    func testDumpViterbi() throws {
        let resources = try TestReadResources.shared()
        UserDefaults.standard.set(true, forKey: SegmenterSettings.viterbiEnabledKey)
        defer { UserDefaults.standard.set(false, forKey: SegmenterSettings.viterbiEnabledKey) }
        dump(label: "VITERBI", segmenter: resources.segmenter)
    }

    private func dump(label: String, segmenter: Segmenter) {
        for phrase in phrases {
            let result = segmenter.longestMatchResult(for: phrase)
            let chosen = result.selectedEdges.map { $0.surface }.joined(separator: " | ")
            print("=== [\(label)] \(phrase) ===")
            print("CHOSEN:  \(chosen)")
            print("LATTICE (start–end : surface : pos? : dict? : decomp? : nodeCost : viterbi)")
            for edge in result.latticeEdges {
                let posLabels = PartOfSpeech.decode(bits: edge.partOfSpeech).map(\.label).joined(separator: ",")
                let dictMark = edge.isDictionaryMatch ? "DICT" : "----"
                let decompMark = edge.decomposesAtGrammaticalEnding ? "DECOMP" : "------"
                let nodeCost = SegmenterScoring.edgeCost(edge)
                let viterbiCost = edge.viterbiScore.map(String.init) ?? "—"
                let s = phrase.distance(from: phrase.startIndex, to: edge.start)
                let e = phrase.distance(from: phrase.startIndex, to: edge.end)
                print(String(format: "  %2d–%2d : %@ : %@ : %@ : %@ : node=%d : best=%@",
                             s, e, edge.surface,
                             posLabels.isEmpty ? "—" : posLabels,
                             dictMark, decompMark, nodeCost, viterbiCost))
            }
            print()
        }
    }
}
