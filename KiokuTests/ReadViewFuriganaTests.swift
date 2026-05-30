import SwiftUI
import XCTest
@testable import Kioku

// Verifies furigana alignment behavior for mixed kanji and kana read-mode segments.
@MainActor
final class ReadViewFuriganaTests: XCTestCase {

    // Builds a lightweight read view backed by the shared real segmenter so furigana helpers use production logic.
    private func makeReadView(
        surfaceReadings: [String: [String]] = [:],
        kanjiReadingFallback: [Character: String] = [:]
    ) throws -> ReadView {
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
            kanjiReadingFallback: KanjiReadingFallbackMap(kanjiReadingFallback),
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

    // Regression: 眩しげ (the appearance "-げ" form of 眩しい) doesn't deinflect to its base
    // adjective and has no surface-reading entry for either the surface or the bare kanji 眩,
    // so every dictionary path produces nothing — the user saw a kanji with no furigana at all.
    // The KANJIDIC2 single-kanji fallback must paint the kanji's standalone reading so *some*
    // ruby always appears over a kanji. The reading need not match the in-context pronunciation.
    func testBuildFuriganaBySegmentLocationUsesKanjiFallbackWhenNoDictionaryReading() throws {
        let readView = try makeReadView(kanjiReadingFallback: ["眩": "まぶ"])
        let sourceText = "眩しげ"
        // A non-dictionary edge (the segmenter couldn't resolve the surface to a known word) is the
        // only case where the last-resort fallback is allowed to fire.
        let edge = LatticeEdge(
            start: sourceText.startIndex,
            end: sourceText.endIndex,
            surface: sourceText,
            isDictionaryMatch: false
        )

        // No surface-reading entries at all: the only reading source is the per-kanji fallback.
        let furigana = readView.buildFuriganaBySegmentLocation(
            for: sourceText,
            edges: [edge],
            surfaceReadingData: makeSurfaceReadingData([:])
        )

        XCTAssertEqual(furigana.furiganaByLocation[0], "まぶ")
        XCTAssertEqual(furigana.lengthByLocation[0], 1)
        XCTAssertNil(furigana.furiganaByLocation[1], "no annotation should attach to the kana しげ")
    }

    // The per-kanji fallback is strictly last-resort: when a dictionary reading already resolves
    // for the kanji run it must win, and the fallback must not double-annotate the same kanji.
    func testKanjiFallbackDoesNotOverrideResolvedDictionaryReading() throws {
        let readView = try makeReadView(kanjiReadingFallback: ["近": "きん"])
        let sourceText = "近づいて"
        let edge = LatticeEdge(
            start: sourceText.startIndex,
            end: sourceText.endIndex,
            surface: sourceText
        )

        let surfaceReadingData = makeSurfaceReadingData([
            "近づく": ["ちかづく"]
        ])
        let furigana = readView.buildFuriganaBySegmentLocation(
            for: sourceText,
            edges: [edge],
            surfaceReadingData: surfaceReadingData
        )

        // The resolved local reading ちか must stand; the fallback きん must not replace it.
        XCTAssertEqual(furigana.furiganaByLocation[0], "ちか")
        XCTAssertEqual(furigana.lengthByLocation[0], 1)
    }

    // The kanji fallback is lowest-priority: it must not fire on dictionary-matched edges. When the
    // segmenter resolved the surface to a known word we trust its reading pipeline (including its
    // deliberate suppressions), so a kanji left un-annotated there stays bare rather than getting a
    // context-free guess painted over it. Only unrecognised (non-dictionary) segments get the net.
    func testKanjiFallbackSuppressedForDictionaryMatchedEdge() throws {
        let readView = try makeReadView(kanjiReadingFallback: ["眩": "まぶ"])
        let sourceText = "眩しげ"
        // Mark the edge as a dictionary match — as if the segmenter resolved it to a known lemma —
        // but provide no reading data, so only the (now-suppressed) fallback could produce ruby.
        let edge = LatticeEdge(
            start: sourceText.startIndex,
            end: sourceText.endIndex,
            surface: sourceText,
            isDictionaryMatch: true
        )

        let furigana = readView.buildFuriganaBySegmentLocation(
            for: sourceText,
            edges: [edge],
            surfaceReadingData: makeSurfaceReadingData([:])
        )

        XCTAssertTrue(furigana.furiganaByLocation.isEmpty)
        XCTAssertTrue(furigana.lengthByLocation.isEmpty)
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

    // docs/INVARIANTS.md "Furigana Resolution" #6 — annotations whose UTF-16 range
    // falls outside every current segment range are dropped during the prune pass.
    // Models the "user edited the note and made the text shorter" path: the old
    // furigana refers to character positions past the end of the new text, so it
    // can't fit in any segment of the new edge layout. Keeping the annotation
    // would render at a stale location (or crash CoreText layout at the boundary).
    //
    // The same pruning logic also fires on subset edits within the text (split,
    // merge, character deletion mid-string) but the simplest end-to-end shape is
    // "text got shorter and the trailing annotation now points past the end."
    func testPruneFuriganaForSegmentationDropsAnnotationsPastShortenedText() throws {
        let readView = try makeReadView()
        // Simulate: user had "物語の続き" with an annotation on 続 at position 3
        // (length 1). User deleted "の続き" leaving just "物語" — the annotation's
        // location 3 is past the new endIndex (UTF-16 length 2 for "物語").
        let shortenedText = "物語"
        let onlyEdge = LatticeEdge(
            start: shortenedText.startIndex,
            end: shortenedText.endIndex,
            surface: "物語"
        )
        // Annotation that fit inside the old text but doesn't fit anywhere in the new edges.
        let staleByLocation: [Int: String] = [3: "つづ"]
        let staleLengthByLocation: [Int: Int] = [3: 1]

        let pruned = readView.pruneFuriganaForSegmentation(
            furiganaByLocation: staleByLocation,
            furiganaLengthByLocation: staleLengthByLocation,
            edges: [onlyEdge],
            sourceText: shortenedText
        )

        XCTAssertTrue(pruned.byLocation.isEmpty,
                      "Annotation past the new edge range must be dropped")
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

    // Disk-poisoned wide entries (e.g. ものご at [0, 2) produced by a synthesis pass that ran
    // before the dictionary loaded, then persisted) must be replaceable by the dict-derived
    // compound reading on a later recompute. Without the synthesized-origin marker, the
    // same-range protection from `testApplyNewAnnotationsPreservesExistingExactMatch` blocks
    // the replacement and the bogus reading lives forever on disk.
    func testApplyNewAnnotationsReplacesSameRangeSynthesizedEntryWithDictCompound() throws {
        let readView = try makeReadView()

        let result = readView.furiganaAfterApplyingNewAnnotations(
            existingByLocation: [0: "ものご"],
            existingLengthByLocation: [0: 2],
            newByLocation: [0: "ものがたり"],
            newLengthByLocation: [0: 2],
            synthesizedLocations: [0]
        )

        XCTAssertEqual(result.byLocation, [0: "ものがたり"])
        XCTAssertEqual(result.lengthByLocation, [0: 2])
        XCTAssertFalse(result.synthesizedLocations.contains(0), "dict-derived replacement clears the synthesized marker")
    }

    // The synthesized-origin gate must NOT clobber user pins. An existing wide entry at the
    // same range that is absent from the synthesized set (e.g. an LLM-corrected reading the
    // user explicitly chose) is preserved even when the recompute produces a different value.
    func testApplyNewAnnotationsPreservesSameRangeUserPinAgainstDifferingDictReading() throws {
        let readView = try makeReadView()

        let result = readView.furiganaAfterApplyingNewAnnotations(
            existingByLocation: [0: "ぶつご"],
            existingLengthByLocation: [0: 2],
            newByLocation: [0: "ものがたり"],
            newLengthByLocation: [0: 2],
            synthesizedLocations: []
        )

        XCTAssertEqual(result.byLocation, [0: "ぶつご"], "untagged same-range entry treated as user pin and preserved")
        XCTAssertEqual(result.lengthByLocation, [0: 2])
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
