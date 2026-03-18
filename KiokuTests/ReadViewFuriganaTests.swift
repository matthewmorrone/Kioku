import SwiftUI
import XCTest
@testable import Kioku

// Verifies furigana alignment behavior for mixed kanji and kana read-mode segments.
final class ReadViewFuriganaTests: XCTestCase {

    // Builds a lightweight read view backed by the shared real segmenter so furigana helpers use production logic.
    private func makeReadView() throws -> ReadView {
        let resources = try TestReadResources.shared()
        return ReadView(
            selectedNote: .constant(nil),
            shouldActivateEditModeOnLoad: .constant(false),
            segmenter: resources.segmenter,
            dictionaryStore: resources.dictionaryStore,
            readingBySurface: [:],
            readingCandidatesBySurface: [:],
            segmenterRevision: 0,
            readResourcesReady: true
        )
    }

    // Verifies voiced okurigana variants do not cause the entire lemma reading to attach to one kanji run.
    func testFirstKanjiRunReadingStripsVoicedOkuriganaVariant() throws {
        let readView = try makeReadView()

        XCTAssertEqual(readView.firstKanjiRunReading(in: "近づく", using: "ちかずく"), "ちか")
        XCTAssertEqual(readView.firstKanjiRunReading(in: "近づく", using: "ちかづく"), "ちか")
    }

    // Verifies mixed kanji+kana segments only annotate the kanji run with its local reading, not the full lemma reading.
    func testBuildFuriganaBySegmentLocationKeepsLocalReadingForNearCompound() throws {
        let readView = try makeReadView()
        let sourceText = "近づいて"
        let edge = LatticeEdge(
            start: sourceText.startIndex,
            end: sourceText.endIndex,
            surface: sourceText
        )

        let furigana = readView.buildFuriganaBySegmentLocation(
            for: sourceText,
            edges: [edge],
            readingBySurface: ["近づく": "ちかずく"],
            readingCandidatesBySurface: ["近づく": ["ちかずく", "ちかづく"]]
        )

        XCTAssertEqual(furigana.furiganaByLocation[0], "ちか")
        XCTAssertEqual(furigana.lengthByLocation[0], 1)
        XCTAssertFalse(furigana.furiganaByLocation.values.contains("ちかずく"))
        XCTAssertFalse(furigana.furiganaByLocation.values.contains("ちかづく"))
    }

    // Verifies first-run extraction rejects lemma readings that do not match kana affixes in the surface form.
    func testFirstKanjiRunReadingRejectsIncompatibleKanaAffixMatch() throws {
        let readView = try makeReadView()

        XCTAssertNil(readView.firstKanjiRunReading(in: "私たち", using: "わたくし"))
    }

    // Verifies mixed kanji+kana surfaces do not attach mismatched lemma readings to the kanji run.
    func testBuildFuriganaBySegmentLocationDoesNotAttachMismatchedLemmaReadingForWatashitachi() throws {
        let readView = try makeReadView()
        let sourceText = "私たち"
        let edge = LatticeEdge(
            start: sourceText.startIndex,
            end: sourceText.endIndex,
            surface: sourceText
        )

        let furigana = readView.buildFuriganaBySegmentLocation(
            for: sourceText,
            edges: [edge],
            readingBySurface: ["私": "わたくし"],
            readingCandidatesBySurface: [:]
        )

        XCTAssertTrue(furigana.furiganaByLocation.isEmpty)
        XCTAssertTrue(furigana.lengthByLocation.isEmpty)
    }
}