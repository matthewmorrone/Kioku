import SwiftUI
import XCTest
@testable import Kioku

// Edit mode keeps segmentation work out of typing: reconcileSegments turns the changed stretch into
// one stub (needsSegmentation) with a string comparison, and segmentsAfterEdit fills the stubs in
// from a whole-text segmentation when the note is shown. These pin both halves, including the case
// that motivated them: 戦 committed by the IME before う was typed must end up as 戦う, not 戦|う.
@MainActor
final class EditedSegmentsTests: XCTestCase {

    // ReadView only as a receiver for the extension methods; nothing here touches the segmenter.
    private func makeReadView() -> ReadView {
        ReadView(
            selectedNote: .constant(nil),
            shouldActivateEditModeOnLoad: .constant(false),
            segmenter: Segmenter(trie: DictionaryTrie()),
            dictionaryStore: nil,
            surfaceReadingData: SurfaceReadingDataMap([:]),
            segmenterRevision: 0,
            readResourcesReady: false
        )
    }

    // Lattice edges tiling `text` with the given surfaces, standing in for the segmenter's output.
    private func edges(_ surfaces: [String], in text: String) -> [LatticeEdge] {
        var start = text.startIndex
        return surfaces.map { surface in
            let end = text.utf16.index(start, offsetBy: surface.utf16.count)
            defer { start = end }
            return LatticeEdge(start: start, end: end, surface: surface)
        }
    }

    // MARK: - reconcileSegments

    // Typing after the last segment keeps every segment and adds the new text as one stub.
    func test_reconcile_appendedTextBecomesOneStub() {
        let readView = makeReadView()
        let existing = [SegmentRange(surface: "涙"), SegmentRange(surface: "は")]
        let reconciled = readView.reconcileSegments(existing, to: "涙は戦う")
        XCTAssertEqual(reconciled?.map(\.surface), ["涙", "は", "戦う"])
        XCTAssertEqual(reconciled?.map { $0.needsSegmentation == true }, [false, false, true])
    }

    // A second keystroke next to the first edit joins its stub instead of starting another, so 戦
    // then う is one stretch the segmenter sees whole.
    func test_reconcile_keystrokesNextToAStubJoinIt() {
        let readView = makeReadView()
        let existing = [SegmentRange(surface: "涙"), SegmentRange(surface: "は")]
        let afterKanji = readView.reconcileSegments(existing, to: "涙は戦")
        let afterKana = afterKanji.flatMap { readView.reconcileSegments($0, to: "涙は戦う") }
        XCTAssertEqual(afterKana?.map(\.surface), ["涙", "は", "戦う"])
        XCTAssertEqual(afterKana?.last?.needsSegmentation, true)
    }

    // Untouched segments on both sides of an edit keep their readings and word picks.
    func test_reconcile_untouchedSegmentsKeepCustomizations() {
        let readView = makeReadView()
        let reading = FuriganaAnnotation(start: 0, end: 1, reading: "なみだ")
        let existing = [
            SegmentRange(surface: "涙", furigana: [reading]),
            SegmentRange(surface: "は"),
            SegmentRange(surface: "行った", chosenEntryID: 42),
        ]
        let reconciled = readView.reconcileSegments(existing, to: "涙が行った")
        XCTAssertEqual(reconciled?.map(\.surface), ["涙", "が", "行った"])
        XCTAssertEqual(reconciled?.first?.furigana, [reading])
        XCTAssertEqual(reconciled?.last?.chosenEntryID, 42)
        XCTAssertEqual(reconciled?[1].needsSegmentation, true)
    }

    // Unchanged text passes through untouched, with no stub.
    func test_reconcile_unchangedTextHasNoStub() {
        let readView = makeReadView()
        let existing = [SegmentRange(surface: "涙"), SegmentRange(surface: "は")]
        let reconciled = readView.reconcileSegments(existing, to: "涙は")
        XCTAssertEqual(reconciled, existing)
        XCTAssertTrue(SegmentRange.isFullySegmented(reconciled ?? []))
    }

    // MARK: - isFullySegmented

    // Any stub makes persisted segments unusable as they are; none means they're final.
    func test_isFullySegmented() {
        XCTAssertTrue(SegmentRange.isFullySegmented([SegmentRange(surface: "涙")]))
        XCTAssertFalse(SegmentRange.isFullySegmented([
            SegmentRange(surface: "涙"),
            SegmentRange(surface: "は", needsSegmentation: true),
        ]))
    }

    // MARK: - segmentsAfterEdit

    // A stub is replaced by the computed words inside it.
    func test_afterEdit_stubTakesComputedWords() {
        let readView = makeReadView()
        let text = "涙は戦う"
        let persisted = [
            SegmentRange(surface: "涙"),
            SegmentRange(surface: "は"),
            SegmentRange(surface: "戦う", needsSegmentation: true),
        ]
        let result = readView.segmentsAfterEdit(persisted, computedEdges: edges(["涙", "は", "戦う"], in: text), in: text)
        XCTAssertEqual(result?.map(\.surface), ["涙", "は", "戦う"])
        XCTAssertTrue(SegmentRange.isFullySegmented(result ?? []))
    }

    // The bug this replaced: 戦 is an untouched segment, う the stub. The computed word 戦う joins
    // them, so 戦 is re-segmented with the edit instead of freezing as 戦|う.
    func test_afterEdit_untouchedNeighbourJoinedByComputedWordIsResegmented() {
        let readView = makeReadView()
        let text = "涙は戦う"
        let persisted = [
            SegmentRange(surface: "涙"),
            SegmentRange(surface: "は"),
            SegmentRange(surface: "戦"),
            SegmentRange(surface: "う", needsSegmentation: true),
        ]
        let result = readView.segmentsAfterEdit(persisted, computedEdges: edges(["涙", "は", "戦う"], in: text), in: text)
        XCTAssertEqual(result?.map(\.surface), ["涙", "は", "戦う"])
    }

    // An untouched segment that differs from the computed segmentation but isn't joined to the edit
    // is a customization: it stays as it is, readings and word pick included, even right next to
    // the edit.
    func test_afterEdit_untouchedCustomizationNextToEditIsKept() {
        let readView = makeReadView()
        let text = "今日は猫がいる"
        let reading = FuriganaAnnotation(start: 0, end: 2, reading: "きょう")
        let persisted = [
            SegmentRange(surface: "今日は", furigana: [reading], chosenEntryID: 7),
            SegmentRange(surface: "猫がいる", needsSegmentation: true),
        ]
        let computed = edges(["今日", "は", "猫", "が", "いる"], in: text)
        let result = readView.segmentsAfterEdit(persisted, computedEdges: computed, in: text)
        XCTAssertEqual(result?.map(\.surface), ["今日は", "猫", "が", "いる"])
        XCTAssertEqual(result?.first?.furigana, [reading])
        XCTAssertEqual(result?.first?.chosenEntryID, 7)
    }

    // A computed word that reaches across an untouched segment drags in the next one too, and so on,
    // until no computed word straddles an edited and an untouched segment.
    func test_afterEdit_growthFollowsComputedWordsAcrossSegments() {
        let readView = makeReadView()
        let text = "あいうえ"
        let persisted = [
            SegmentRange(surface: "あ"),
            SegmentRange(surface: "い"),
            SegmentRange(surface: "う"),
            SegmentRange(surface: "え", needsSegmentation: true),
        ]
        let result = readView.segmentsAfterEdit(persisted, computedEdges: edges(["あ", "いう", "え"], in: text), in: text)
        XCTAssertEqual(result?.map(\.surface), ["あ", "い", "う", "え"],
            "いう doesn't touch the stub え, so い and う stay as they are")

        let joined = readView.segmentsAfterEdit(persisted, computedEdges: edges(["あ", "い", "うえ"], in: text), in: text)
        XCTAssertEqual(joined?.map(\.surface), ["あ", "い", "うえ"])

        // いう straddles both computed words: うえ pulls it in, and then あい, which now touches it,
        // pulls in あ.
        let straddling = [
            SegmentRange(surface: "あ"),
            SegmentRange(surface: "いう"),
            SegmentRange(surface: "え", needsSegmentation: true),
        ]
        let chained = readView.segmentsAfterEdit(straddling, computedEdges: edges(["あい", "うえ"], in: text), in: text)
        XCTAssertEqual(chained?.map(\.surface), ["あい", "うえ"])
    }

    // Segments or edges that don't tile the text are rejected so the caller falls back to the
    // computed segmentation alone.
    func test_afterEdit_mismatchedInputsReturnNil() {
        let readView = makeReadView()
        let text = "涙は"
        let persisted = [SegmentRange(surface: "涙"), SegmentRange(surface: "が", needsSegmentation: true)]
        XCTAssertNil(readView.segmentsAfterEdit(persisted, computedEdges: edges(["涙", "は"], in: text), in: text))
    }
}
