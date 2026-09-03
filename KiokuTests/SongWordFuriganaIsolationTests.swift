import XCTest
@testable import Kioku

// Reproduction for: a Breakdown word-list headword whose surface doesn't appear verbatim in
// its line (SongStepperView+Furigana's "LLM-normalized headword" fallback) used to come back
// with wrong per-kanji furigana for a real compound word — e.g. 王子様 "prince" split into
// 王/子/様, each read in isolation (お/こ/さま) instead of the correct おうじさま. Root cause:
// the fallback asked the segmenter to rediscover word boundaries inside a string it already
// knew was one word (a SongWord bullet is atomic by construction), and with no surrounding
// sentence to weigh frequency against, the segmenter's cost model can prefer splitting a
// compound into individually-common kanji over the compound itself when the compound's own
// frequency rank is worse than its parts' — true for 王子様 (jpdb_rank ~9999999, i.e.
// effectively unranked) versus its parts. Fixed by treating the surface as a single synthetic
// edge instead of re-segmenting it. Uses the real production segmenter/dictionary (via
// TestReadResources), same as SavedGlowLemmaBridgeTests, since this is a real trie/cost-model
// behavior, not something a stub segmenter could reproduce.
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

    // Characterizes the bug this replaced: segmenting the bare 3-character surface alone (no
    // sentence context) can split a real compound into its individual kanji. This test doesn't
    // assert the OLD behavior is still wrong (that code path is gone) — it documents why the
    // fix was necessary by confirming the segmenter's own frequency data ranks the compound
    // worse than at least one of its parts, which is what made the isolated split possible.
    func testCompoundFrequencyRankIsWorseThanItsParts() throws {
        let resources = try TestReadResources.shared()
        let frequencyBySurface = (try? resources.dictionaryStore.fetchFrequencyScoreBySurface()) ?? [:]
        let compoundScore = frequencyBySurface["王子様"] ?? 0
        let partScore = frequencyBySurface["王子"] ?? 0
        XCTAssertLessThan(compoundScore, partScore, "expected 王子様's frequency score to be worse than 王子's — this is why isolated (no-context) segmentation could prefer splitting it")
    }
}
