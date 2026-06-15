import XCTest
@testable import Kioku

// Reproduction for: conjugated favorited words don't get the in-text golden glow, while their
// base forms do. The glow predicate is ComputedSavedWordState.isSavedSurface, which is supposed to
// bridge a conjugated segment (消えて) to its saved lemma (消える) via the segmenter's preferredLemma.
// These tests instrument that bridge with the real production segmenter to show WHERE it breaks.
@MainActor
final class FavoritedGlowLemmaBridgeTests: XCTestCase {

    private func resolver(_ segmenter: any TextSegmenting) -> (String) -> String? {
        { segmenter.preferredLemma(for: $0) }
    }

    func testConjugatedSegmentGlowsForSavedLemma() throws {
        let resources = try TestReadResources.shared()
        let segmenter = resources.segmenter
        let resolve = resolver(segmenter)

        // Simulate favoriting the base form (lemma-normalized save — what the lookup-sheet star does).
        let saved = SavedWord(canonicalEntryID: 1, surface: "消える")
        let (state, _) = SegmentListView.computeSavedWordState(
            entries: [saved], lemmaResolver: resolve, lemmaCache: [:])

        XCTAssertTrue(state.isSavedSurface("消える", lemmaResolver: resolve),
                      "base form 消える must match its own saved card")
        XCTAssertTrue(state.isSavedSurface("消えて", lemmaResolver: resolve),
                      "conjugated 消えて must bridge to the saved lemma 消える and glow")
    }

    func testConjugatedSegmentGlowsForSavedConjugatedCard() throws {
        let resources = try TestReadResources.shared()
        let segmenter = resources.segmenter
        let resolve = resolver(segmenter)

        // Simulate favoriting the conjugated form directly (surface stored as 消えて).
        let saved = SavedWord(canonicalEntryID: 1, surface: "消えて")
        let (state, _) = SegmentListView.computeSavedWordState(
            entries: [saved], lemmaResolver: resolve, lemmaCache: [:])

        XCTAssertTrue(state.isSavedSurface("消えて", lemmaResolver: resolve),
                      "the saved conjugated surface must match itself")
        XCTAssertTrue(state.isSavedSurface("消える", lemmaResolver: resolve),
                      "the base-form segment must also light up the conjugated card")
    }
}
