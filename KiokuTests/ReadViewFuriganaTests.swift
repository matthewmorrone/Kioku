import SwiftUI
import XCTest
@testable import Kioku

// Verifies furigana alignment behavior for mixed kanji and kana read-mode segments.
final class ReadViewFuriganaTests: XCTestCase {

    // Builds a lightweight read view backed by the shared real segmenter so furigana helpers use production logic.
    private func makeReadView(surfaceReadings: [String: [String]] = [:]) throws -> ReadView {
        let resources = try TestReadResources.shared()
        let dataMap = surfaceReadings.mapValues { readings in
            SurfaceReadingData(readings: readings, frequencyByReading: [:])
        }
        return ReadView(
            selectedNote: .constant(nil),
            shouldActivateEditModeOnLoad: .constant(false),
            segmenter: resources.segmenter,
            dictionaryStore: resources.dictionaryStore,
            surfaceReadingData: SurfaceReadingDataMap(dataMap),
            segmenterRevision: 0,
            readResourcesReady: true
        )
    }

    private func makeSurfaceReadingData(_ entries: [String: [String]]) -> SurfaceReadingDataMap {
        let mapped = entries.mapValues { readings in
            SurfaceReadingData(readings: readings, frequencyByReading: [:])
        }
        return SurfaceReadingDataMap(mapped)
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

        let surfaceReadingData = makeSurfaceReadingData([
            "近づく": ["ちかずく", "ちかづく"]
        ])
        let furigana = readView.buildFuriganaBySegmentLocation(
            for: sourceText,
            edges: [edge],
            surfaceReadingData: surfaceReadingData
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

        let surfaceReadingData = makeSurfaceReadingData([
            "私": ["わたくし"]
        ])
        let furigana = readView.buildFuriganaBySegmentLocation(
            for: sourceText,
            edges: [edge],
            surfaceReadingData: surfaceReadingData
        )

        XCTAssertTrue(furigana.furiganaByLocation.isEmpty)
        XCTAssertTrue(furigana.lengthByLocation.isEmpty)
    }

    // Regression: 抜け殻 has two kanji runs (抜 and 殻) separated by kana (け). Both runs must
    // receive their projected readings (ぬ and がら) — earlier behaviour stopped producing the
    // second run's annotation when partial entries were already in memory from a prior pass.
    func testBuildFuriganaBySegmentLocationProjectsBothRunsForNukegara() throws {
        let readView = try makeReadView()
        let sourceText = "抜け殻"
        let edge = LatticeEdge(
            start: sourceText.startIndex,
            end: sourceText.endIndex,
            surface: sourceText
        )

        let surfaceReadingData = makeSurfaceReadingData([
            "抜け殻": ["ぬけがら"]
        ])
        let furigana = readView.buildFuriganaBySegmentLocation(
            for: sourceText,
            edges: [edge],
            surfaceReadingData: surfaceReadingData
        )

        // 抜 sits at UTF-16 location 0, 殻 sits at location 2 (け is one UTF-16 unit between them).
        XCTAssertEqual(furigana.furiganaByLocation[0], "ぬ")
        XCTAssertEqual(furigana.lengthByLocation[0], 1)
        XCTAssertEqual(furigana.furiganaByLocation[2], "がら")
        XCTAssertEqual(furigana.lengthByLocation[2], 1)
        XCTAssertNil(furigana.furiganaByLocation[1], "no annotation should attach to the kana け")
    }

    // Regression: when surface_readings is missing the compound (e.g. no 抜け殻 → ぬけがら entry),
    // the per-run fallback must still produce dictionary readings for each individual kanji
    // rather than silently skipping the whole segment. Showing per-kanji defaults is better
    // than showing nothing above a kanji that has a known reading.
    func testBuildFuriganaBySegmentLocationFallsBackToPerKanjiReadingsForMultiRunCompound() throws {
        let readView = try makeReadView()
        let sourceText = "抜け殻"
        let edge = LatticeEdge(
            start: sourceText.startIndex,
            end: sourceText.endIndex,
            surface: sourceText
        )

        // Only the per-kanji entries are present — the compound 抜け殻 is intentionally missing
        // so projection cannot succeed. Without a multi-run-aware fallback both runs would be
        // dropped, which is exactly what the user reported.
        let surfaceReadingData = makeSurfaceReadingData([
            "抜": ["ぬ"],
            "殻": ["から"]
        ])
        let furigana = readView.buildFuriganaBySegmentLocation(
            for: sourceText,
            edges: [edge],
            surfaceReadingData: surfaceReadingData
        )

        XCTAssertEqual(furigana.furiganaByLocation[0], "ぬ")
        XCTAssertEqual(furigana.lengthByLocation[0], 1)
        XCTAssertEqual(furigana.furiganaByLocation[2], "から")
        XCTAssertEqual(furigana.lengthByLocation[2], 1)
    }

    // Regression: merging single-kanji segments (物 + 語 → 物語) into a compound with a single
    // contiguous kanji run must clear the prior per-character furigana entries so the recompute
    // can install one span-wide reading. Without the prune both per-character entries linger
    // (backfill never overwrites) and the compound renders with two ruby frames instead of one.
    func testPruneFuriganaForSegmentationDropsPerCharacterEntriesAfterMergingContiguousKanji() throws {
        let readView = try makeReadView()
        let sourceText = "物語"
        let mergedEdge = LatticeEdge(
            start: sourceText.startIndex,
            end: sourceText.endIndex,
            surface: sourceText
        )

        // Prior segmentation: 物 and 語 as two separate segments, each carrying its own per-kanji
        // furigana entry at UTF-16 location 0 (length 1) and location 1 (length 1).
        let priorByLocation: [Int: String] = [0: "もの", 1: "がたり"]
        let priorLengthByLocation: [Int: Int] = [0: 1, 1: 1]

        let pruned = readView.pruneFuriganaForSegmentation(
            furiganaByLocation: priorByLocation,
            furiganaLengthByLocation: priorLengthByLocation,
            edges: [mergedEdge],
            sourceText: sourceText
        )

        XCTAssertTrue(pruned.byLocation.isEmpty, "per-character entries must be cleared on merge of contiguous kanji")
        XCTAssertTrue(pruned.lengthByLocation.isEmpty)
    }

    // Regression: pruning must NOT drop per-run entries on multi-run compounds. 抜け殻 has two
    // kanji runs separated by kana (抜 at [0,1), 殻 at [2,3)), and the per-run entries at those
    // exact ranges remain valid — each entry matches its kanji run boundaries.
    func testPruneFuriganaForSegmentationPreservesPerRunEntriesOnMultiRunCompound() throws {
        let readView = try makeReadView()
        let sourceText = "抜け殻"
        let edge = LatticeEdge(
            start: sourceText.startIndex,
            end: sourceText.endIndex,
            surface: sourceText
        )

        let priorByLocation: [Int: String] = [0: "ぬ", 2: "がら"]
        let priorLengthByLocation: [Int: Int] = [0: 1, 2: 1]

        let pruned = readView.pruneFuriganaForSegmentation(
            furiganaByLocation: priorByLocation,
            furiganaLengthByLocation: priorLengthByLocation,
            edges: [edge],
            sourceText: sourceText
        )

        XCTAssertEqual(pruned.byLocation[0], "ぬ")
        XCTAssertEqual(pruned.lengthByLocation[0], 1)
        XCTAssertEqual(pruned.byLocation[2], "がら")
        XCTAssertEqual(pruned.lengthByLocation[2], 1)
    }

    // A segment-wide entry (the fallback case in buildFuriganaBySegmentLocation) must survive
    // pruning because its UTF-16 range matches the segment exactly.
    func testPruneFuriganaForSegmentationPreservesSegmentWideFallbackEntry() throws {
        let readView = try makeReadView()
        let sourceText = "物語"
        let edge = LatticeEdge(
            start: sourceText.startIndex,
            end: sourceText.endIndex,
            surface: sourceText
        )

        let priorByLocation: [Int: String] = [0: "ものがたり"]
        let priorLengthByLocation: [Int: Int] = [0: 2]

        let pruned = readView.pruneFuriganaForSegmentation(
            furiganaByLocation: priorByLocation,
            furiganaLengthByLocation: priorLengthByLocation,
            edges: [edge],
            sourceText: sourceText
        )

        XCTAssertEqual(pruned.byLocation[0], "ものがたり")
        XCTAssertEqual(pruned.lengthByLocation[0], 2)
    }
}
