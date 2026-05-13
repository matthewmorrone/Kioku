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

    // The gentle prune keeps fragmented per-character entries inside a merged segment so the
    // recompute can decide their fate: replace-on-overlap collapses them when a compound reading
    // is available, and the synthesis fallback concatenates them otherwise. Dropping fragments
    // here would forfeit the synthesis path for coined compounds that have no dictionary reading.
    func testPruneFuriganaForSegmentationKeepsPerCharacterFragmentsInsideMergedSegment() throws {
        let readView = try makeReadView()
        let sourceText = "物語"
        let mergedEdge = LatticeEdge(
            start: sourceText.startIndex,
            end: sourceText.endIndex,
            surface: sourceText
        )

        let priorByLocation: [Int: String] = [0: "もの", 1: "がたり"]
        let priorLengthByLocation: [Int: Int] = [0: 1, 1: 1]

        let pruned = readView.pruneFuriganaForSegmentation(
            furiganaByLocation: priorByLocation,
            furiganaLengthByLocation: priorLengthByLocation,
            edges: [mergedEdge],
            sourceText: sourceText
        )

        XCTAssertEqual(pruned.byLocation, priorByLocation, "fragments inside the merged segment must be preserved for the recompute")
        XCTAssertEqual(pruned.lengthByLocation, priorLengthByLocation)
    }

    // The gentle prune drops wide entries that no longer fit any segment after a split — e.g.
    // a span-wide ものがたり at [0, 2) becomes stale when 物語 is split back into 物 and 語, since
    // each successor segment is only one UTF-16 unit wide.
    func testPruneFuriganaForSegmentationDropsWideEntriesAfterSplit() throws {
        let readView = try makeReadView()
        let sourceText = "物語"
        let leftEdge = LatticeEdge(
            start: sourceText.startIndex,
            end: sourceText.index(after: sourceText.startIndex),
            surface: "物"
        )
        let rightEdge = LatticeEdge(
            start: sourceText.index(after: sourceText.startIndex),
            end: sourceText.endIndex,
            surface: "語"
        )

        let priorByLocation: [Int: String] = [0: "ものがたり"]
        let priorLengthByLocation: [Int: Int] = [0: 2]

        let pruned = readView.pruneFuriganaForSegmentation(
            furiganaByLocation: priorByLocation,
            furiganaLengthByLocation: priorLengthByLocation,
            edges: [leftEdge, rightEdge],
            sourceText: sourceText
        )

        XCTAssertTrue(pruned.byLocation.isEmpty, "wide entry must be dropped when no successor segment can hold it")
        XCTAssertTrue(pruned.lengthByLocation.isEmpty)
    }

    // Replace-on-overlap: a new annotation that strictly contains existing fragments (compound
    // reading ものがたり at [0, 2) over prior per-character entries もの at [0, 1) and がたり at
    // [1, 2)) supersedes the fragments. This is what collapses the two-ruby-frame state into a
    // single span when the user merges 物 + 語 into 物語 and the dictionary has the compound.
    func testApplyNewAnnotationsReplacesFragmentedEntriesWithWiderCompound() throws {
        let readView = try makeReadView()

        let result = readView.furiganaAfterApplyingNewAnnotations(
            existingByLocation: [0: "もの", 1: "がたり"],
            existingLengthByLocation: [0: 1, 1: 1],
            newByLocation: [0: "ものがたり"],
            newLengthByLocation: [0: 2]
        )

        XCTAssertEqual(result.byLocation, [0: "ものがたり"])
        XCTAssertEqual(result.lengthByLocation, [0: 2])
    }

    // Backfill preserves existing entries at exact-same ranges so user pins and prior-correct
    // annotations are not clobbered when the recompute produces the same annotation.
    func testApplyNewAnnotationsPreservesExistingExactMatch() throws {
        let readView = try makeReadView()

        let result = readView.furiganaAfterApplyingNewAnnotations(
            existingByLocation: [0: "ぬ", 2: "がら"],
            existingLengthByLocation: [0: 1, 2: 1],
            newByLocation: [0: "ぬ", 2: "がら"],
            newLengthByLocation: [0: 1, 2: 1]
        )

        XCTAssertEqual(result.byLocation, [0: "ぬ", 2: "がら"])
        XCTAssertEqual(result.lengthByLocation, [0: 1, 2: 1])
    }

    // Synthesis: when the recompute finds no compound reading for a merged surface (e.g. coined
    // 月色 has no JMdict entry but 月 and 色 individually do), concatenate the per-character
    // fragments inside the kanji run into a single ruby span "つきいろ" over the compound.
    func testSynthesizeCompoundReadingsConcatenatesPerCharacterFragmentsWhenNoCompoundReading() throws {
        let readView = try makeReadView()
        let sourceText = "月色"
        let edge = LatticeEdge(
            start: sourceText.startIndex,
            end: sourceText.endIndex,
            surface: sourceText
        )

        let result = readView.furiganaAfterSynthesizingCompoundReadings(
            furiganaByLocation: [0: "つき", 1: "いろ"],
            furiganaLengthByLocation: [0: 1, 1: 1],
            edges: [edge],
            sourceText: sourceText
        )

        XCTAssertEqual(result.byLocation, [0: "つきいろ"])
        XCTAssertEqual(result.lengthByLocation, [0: 2])
    }

    // Synthesis is a no-op when a span-wide annotation already exists at the kanji run's range —
    // the dictionary compound reading always wins over a synthesized concatenation.
    func testSynthesizeCompoundReadingsLeavesSpanWideAnnotationsUntouched() throws {
        let readView = try makeReadView()
        let sourceText = "物語"
        let edge = LatticeEdge(
            start: sourceText.startIndex,
            end: sourceText.endIndex,
            surface: sourceText
        )

        let result = readView.furiganaAfterSynthesizingCompoundReadings(
            furiganaByLocation: [0: "ものがたり"],
            furiganaLengthByLocation: [0: 2],
            edges: [edge],
            sourceText: sourceText
        )

        XCTAssertEqual(result.byLocation, [0: "ものがたり"])
        XCTAssertEqual(result.lengthByLocation, [0: 2])
    }

    // Synthesis does not concatenate per-run entries on multi-run compounds — each entry sits
    // over its own single-character kanji run, so there is nothing to consolidate within a run.
    // 抜け殻 keeps its ぬ over 抜 and がら over 殻 as separate frames.
    func testSynthesizeCompoundReadingsLeavesPerRunEntriesOnMultiRunCompound() throws {
        let readView = try makeReadView()
        let sourceText = "抜け殻"
        let edge = LatticeEdge(
            start: sourceText.startIndex,
            end: sourceText.endIndex,
            surface: sourceText
        )

        let result = readView.furiganaAfterSynthesizingCompoundReadings(
            furiganaByLocation: [0: "ぬ", 2: "がら"],
            furiganaLengthByLocation: [0: 1, 2: 1],
            edges: [edge],
            sourceText: sourceText
        )

        XCTAssertEqual(result.byLocation, [0: "ぬ", 2: "がら"])
        XCTAssertEqual(result.lengthByLocation, [0: 1, 2: 1])
    }

    // Synthesis skips runs that are only partially tiled by fragments — a gap means we can't
    // produce a faithful concatenation, so the run is left as-is rather than synthesizing a
    // potentially wrong reading.
    func testSynthesizeCompoundReadingsSkipsPartiallyTiledRuns() throws {
        let readView = try makeReadView()
        let sourceText = "月日色"
        let edge = LatticeEdge(
            start: sourceText.startIndex,
            end: sourceText.endIndex,
            surface: sourceText
        )

        let result = readView.furiganaAfterSynthesizingCompoundReadings(
            furiganaByLocation: [0: "つき", 2: "いろ"],
            furiganaLengthByLocation: [0: 1, 2: 1],
            edges: [edge],
            sourceText: sourceText
        )

        XCTAssertEqual(result.byLocation, [0: "つき", 2: "いろ"])
        XCTAssertEqual(result.lengthByLocation, [0: 1, 2: 1])
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
