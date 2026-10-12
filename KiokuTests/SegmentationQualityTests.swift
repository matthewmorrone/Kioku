import XCTest
@testable import Kioku

// Guards segmentation QUALITY, which the rest of the suite does not: the lattice and deinflection
// tests pass whether the chosen path is 80% or 89% right, and stayed green while the app's
// segmenter was wired to the wrong frequency map.
//
// Gold tokens come from Tatoeba's Japanese indices (the Tanaka Corpus "B lines"): sentences
// tokenized into JMdict headwords by the JMdict maintainers — the same granularity this segmenter
// aims for. The 300 fixture sentences are held out: nothing in SegmenterScoring was fitted on them.
// Re-measure or refit with scripts/segmentation-eval (see its README). Individual cases the segmenter must
// get right live in Fixtures/segmentation/named-cases.json (NamedSegmentationCasesTests).
@MainActor
final class SegmentationQualityTests: XCTestCase {

    // One fixture sentence: its text and the character spans of its gold tokens.
    private struct GoldSentence: Decodable {
        let text: String
        let tokens: [[Int]]
    }

    // Loads the held-out gold fixture checked in beside this file.
    private func loadGoldSentences() throws -> [GoldSentence] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/segmentation/held-out-gold.jsonl")
        let decoder = JSONDecoder()
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { try decoder.decode(GoldSentence.self, from: Data($0.utf8)) }
    }

    // Segments `text` with the shipped default strategy and returns each segment's character span.
    private func segmentSpans(of text: String, using segmenter: Segmenter) -> [(start: Int, end: Int)] {
        var spans: [(start: Int, end: Int)] = []
        var offset = 0
        for edge in segmenter.longestMatchEdges(for: text) {
            spans.append((start: offset, end: offset + edge.surface.count))
            offset += edge.surface.count
        }
        return spans
    }

    // The quality floor. Each gold token is either reproduced exactly, cut through by one of our
    // segments (a segment that overlaps it partially — the real error, e.g. はだ|きしめたい), or
    // merged/split at a coarser or finer granularity. The floors sit well below what the shipped
    // model scores on this fixture (exact 92.1%, cut-through 0.21%, measured 2026-09-26 with
    // scripts/segmentation-eval) and well above what the two regressions seen in practice score:
    // the segmenter fed per-entry propagated ranks (85.0% / 1.62%, commit c0bdda1) and the greedy
    // strategy with its demotion list (82.6% / 3.03%).
    func testHeldOutQualityFloor() throws {
        UserDefaults.standard.removeObject(forKey: SegmenterSettings.strategyKey)
        let segmenter = try TestReadResources.shared().segmenter
        var goldCount = 0
        var exactCount = 0
        var cutThroughCount = 0

        for sentence in try loadGoldSentences() {
            let spans = segmentSpans(of: sentence.text, using: segmenter)
            for token in sentence.tokens {
                let (start, end) = (token[0], token[1])
                goldCount += 1
                let overlapping = spans.filter { $0.start < end && $0.end > start }
                if overlapping.count == 1, overlapping[0].start == start, overlapping[0].end == end {
                    exactCount += 1
                } else if overlapping.contains(where: { span in
                    (span.start < start || span.end > end) && !(span.start <= start && span.end >= end)
                }) {
                    cutThroughCount += 1
                }
            }
        }

        let exactRate = Double(exactCount) / Double(goldCount)
        let cutThroughRate = Double(cutThroughCount) / Double(goldCount)
        XCTAssertGreaterThanOrEqual(exactRate, 0.90, "exact-match rate fell to \(exactRate) over \(goldCount) gold tokens")
        XCTAssertLessThanOrEqual(cutThroughRate, 0.008, "cut-through rate rose to \(cutThroughRate) over \(goldCount) gold tokens")
    }

    // The transition table is loaded by the constructor the app and the tests share. If it fails to
    // load, segmentation silently falls back to word costs alone and most named cases still hold.
    func testTransitionTableIsLoaded() throws {
        XCTAssertNotNil(try TestReadResources.shared().segmenter.transitionTable)
    }

    // 行く is the one godan く-verb whose past is った, not いた; 行った must reach 行く, not only 行う.
    func testIttaResolvesToIku() throws {
        let lemmas = try TestReadResources.shared().segmenter.resolvedTrieLemmas(for: "行った")
        XCTAssertTrue(lemmas.contains("行く"), "行った resolved to \(lemmas.sorted())")
    }
}
