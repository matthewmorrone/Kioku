import Foundation
import XCTest
@testable import Kioku

// Verifies ReadingVariants gathers every reading that shares a kanji spelling, each tied to its own
// JMdict entry, against the real bundled dictionary. 抱く is the canonical heteronym: one spelling,
// three readings (いだく / だく / うだく) living in three separate entries — the exact case the Words-tab
// reading switcher exists to surface.
@MainActor
final class ReadingVariantsTests: XCTestCase {

    // Real dictionary-backed inputs for ReadingVariants, built once per process.
    private struct Resources {
        let lexicon: Lexicon
        let store: DictionaryStore
        let segmenter: Segmenter
        let surfaceReadingData: SurfaceReadingDataMap
    }

    nonisolated(unsafe) private static var cached: Resources?

    // Assembles (and caches) the lexicon/store/segmenter/reading-map quartet ReadingVariants needs.
    private func resources() throws -> Resources {
        if let cached = Self.cached { return cached }
        let base = try TestReadResources.shared()
        let grouped = try TestReadResources.groupedDeinflectionRules()
        let readingData = try base.dictionaryStore.fetchSurfaceReadingData()
        let deinflector = Deinflector(groupedRules: grouped, trie: DictionaryTrie())
        let lexicon = Lexicon(
            dictionaryStore: base.dictionaryStore,
            segmenter: base.segmenter,
            deinflector: deinflector,
            surfaceReadingData: readingData
        )
        let built = Resources(
            lexicon: lexicon,
            store: base.dictionaryStore,
            segmenter: base.segmenter,
            surfaceReadingData: SurfaceReadingDataMap(readingData)
        )
        Self.cached = built
        return built
    }

    // Gathers variants for the 抱く lemma in this suite's standard configuration.
    private func variantsForIdaku() throws -> [ReadingVariants.Variant] {
        let res = try resources()
        return ReadingVariants.variants(
            surface: "抱く",
            lexicon: res.lexicon,
            store: res.store,
            segmenter: res.segmenter,
            surfaceReadingData: res.surfaceReadingData
        )
    }

    // The two everyday readings of 抱く must both surface.
    func testGathersBothEverydayReadings() throws {
        let readings = try variantsForIdaku().map(\.reading)
        XCTAssertTrue(readings.contains("いだく"), "expected いだく among \(readings)")
        XCTAssertTrue(readings.contains("だく"), "expected だく among \(readings)")
    }

    // Each reading must resolve to a distinct entry whose own kana form is exactly that reading —
    // this is what lets the switcher re-point to a different definition per reading.
    func testEachReadingTiesToDistinctMatchingEntry() throws {
        let variants = try variantsForIdaku()
        let idaku = variants.first { $0.reading == "いだく" }
        let daku = variants.first { $0.reading == "だく" }

        let idakuEntry = try XCTUnwrap(idaku?.entry, "いだく should resolve to an entry")
        let dakuEntry = try XCTUnwrap(daku?.entry, "だく should resolve to an entry")

        XCTAssertNotEqual(idakuEntry.entryId, dakuEntry.entryId, "readings must point at different entries")
        XCTAssertTrue(idakuEntry.kanaForms.contains { $0.text == "いだく" })
        XCTAssertTrue(dakuEntry.kanaForms.contains { $0.text == "だく" })
    }

    // The archaic gate must classify only the archaic うだく entry as low-priority, leaving the two
    // everyday readings switchable when the user has not opted into archaic readings.
    func testArchaicReadingIsIdentifiableForFiltering() throws {
        let variants = try variantsForIdaku()
        let idakuEntry = try XCTUnwrap(variants.first { $0.reading == "いだく" }?.entry)
        let dakuEntry = try XCTUnwrap(variants.first { $0.reading == "だく" }?.entry)
        XCTAssertFalse(DefaultSenseSelection.isEntirelyLowPriority(idakuEntry))
        XCTAssertFalse(DefaultSenseSelection.isEntirelyLowPriority(dakuEntry))

        if let udakuEntry = variants.first(where: { $0.reading == "うだく" })?.entry {
            XCTAssertTrue(
                DefaultSenseSelection.isEntirelyLowPriority(udakuEntry),
                "the archaic うだく entry should be filterable as low-priority"
            )
        }
    }

    // A single-reading word must yield at most one distinct entry so the switcher stays hidden.
    func testSingleReadingWordExposesOneReading() throws {
        let res = try resources()
        let variants = ReadingVariants.variants(
            surface: "食べる",
            lexicon: res.lexicon,
            store: res.store,
            segmenter: res.segmenter,
            surfaceReadingData: res.surfaceReadingData
        )
        let distinctReadings = Set(variants.map(\.reading))
        XCTAssertEqual(distinctReadings, ["たべる"], "食べる has one reading; got \(distinctReadings)")
    }
}
