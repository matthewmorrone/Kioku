import XCTest
@testable import Kioku

// A Breakdown word-list headword whose surface doesn't appear verbatim in its line
// (SongStepperView+ Furigana's "LLM-normalized headword" fallback) must keep its compound reading:
// 王子様 "prince" reads おうじさま, not 王/子/様 each read in isolation (お/こ/さま). The fallback treats the
// surface as a single synthetic edge rather than re-segmenting it, because with no surrounding
// sentence to weigh frequency against, the segmenter's cost model can prefer splitting a compound
// into individually-common kanji when the compound's own frequency rank is worse than its parts' —
// true for 王子様 (frequency_rank ~9999999, i.e. effectively unranked). Uses the real production
// segmenter/dictionary (via TestReadResources), same as SavedGlowLemmaBridgeTests, since this is a
// real trie/cost-model behavior, not something a stub segmenter could reproduce.
@MainActor
final class SongWordFuriganaIsolationTests: XCTestCase {
    private func surfaceReadingData() throws -> SurfaceReadingDataMap {
        let resources = try TestReadResources.shared()
        return SurfaceReadingDataMap(try resources.dictionaryStore.fetchSurfaceReadingData())
    }

    // The fix: a single edge spanning the whole surface resolves it as one compound word,
    // matching SongStepperView+Furigana.buildWordFuriganaRunReadings(for surface:)'s current
    // (post-fix) construction.
    func testWholeWordEdgeResolvesCompoundCorrectly() throws {
        let resources = try TestReadResources.shared()
        let segmenter = resources.segmenter
        let readingData = try surfaceReadingData()
        let surface = "王子様"

        let wholeWordEdge = LatticeEdge(
            start: surface.startIndex,
            end: surface.endIndex,
            surface: surface,
            lemma: segmenter.preferredLemma(for: surface) ?? surface
        )
        let result = FuriganaResolver(segmenter: segmenter).build(
            for: surface,
            edges: [wholeWordEdge],
            surfaceReadingData: readingData
        )

        XCTAssertEqual(result.byLocation, [0: "おうじさま"], "expected one reading spanning the whole word, got \(result.byLocation)")
    }

    // Why the single-edge fallback is needed: confirms the segmenter's own frequency data ranks the
    // compound worse than at least one of its parts, which is what makes an isolated split
    // possible.
    func testCompoundFrequencyRankIsWorseThanItsParts() throws {
        let resources = try TestReadResources.shared()
        let frequencyBySurface = (try? resources.dictionaryStore.fetchFrequencyScoreBySurface()) ?? [:]
        let compoundScore = frequencyBySurface["王子様"] ?? 0
        let partScore = frequencyBySurface["王子"] ?? 0
        XCTAssertLessThan(
            compoundScore,
            partScore,
            "expected 王子様's frequency score to be worse than 王子's — this is why isolated (no-context) segmentation could prefer splitting it"
        )
    }
}
