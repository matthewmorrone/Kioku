import SwiftUI
import XCTest
@testable import Kioku

// Round-trip tests for the persistence boundary between in-memory segmentation/furigana
// state and the on-disk SegmentRange representation. Rationale (E1/E2 invariants):
//
//  - The renderer relies on segments + furigana matching disk byte-for-byte after a
//    save → load cycle. Drift here would silently lose user edits (custom merges,
//    pinned readings) on app relaunch.
//  - These functions live as extensions on ReadView, but the persistence helpers don't
//    actually depend on ReadView's @State — they take text/edges/segments as parameters
//    directly. We instantiate ReadView only because Swift extension methods need a
//    receiver; the body of each call is pure.
@MainActor
final class SegmentPersistenceRoundTripTests: XCTestCase {

    // Lightweight ReadView; only used to call extension methods. The persistence helpers
    // exercised here (`edgesFromSegmentRanges`, `buildSegmentRanges`,
    // `furiganaFromSegmentRanges`) are pure data manipulation — they don't query the
    // segmenter or dictionary — so we wire empty/no-op deps to avoid loading the full
    // trie. (Using `TestReadResources.shared()` here would block the test for 30+s on
    // first run while the trie loads, even though we never use it.)
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

    // E1: persisted SegmentRanges round-trip back to LatticeEdges with surfaces and
    // boundaries that exactly cover the source text. This is the core load-time
    // invariant — without it, normalizedSegmentRanges would reject the persisted data
    // and the segmenter would have to recompute from scratch on every load.
    func test_segments_roundTripThroughEdgesPreservingSurfacesAndCoverage() throws {
        let readView = makeReadView()
        let text = "今日は猫がいる"
        let segments: [SegmentRange] = [
            SegmentRange(surface: "今日"),
            SegmentRange(surface: "は"),
            SegmentRange(surface: "猫"),
            SegmentRange(surface: "が"),
            SegmentRange(surface: "いる"),
        ]

        let edges = readView.edgesFromSegmentRanges(segments, in: text)
        XCTAssertNotNil(edges, "Valid persisted segments must rebuild into edges.")
        guard let edges else { return }

        let rebuiltText = edges.map { String(text[$0.start..<$0.end]) }.joined()
        XCTAssertEqual(rebuiltText, text, "Concatenated edge surfaces must equal the source text.")

        let rebuiltSurfaces = edges.map(\.surface)
        XCTAssertEqual(rebuiltSurfaces, segments.map(\.surface),
            "Edge surfaces must preserve the persisted segment surfaces in order.")
    }

    // E1 negative case: persisted segments whose surfaces don't concatenate to the
    // source text are rejected. Without this guard, a stale persisted snapshot could
    // bind to mid-character offsets and produce broken segmentation that the rest of
    // the system would treat as valid.
    func test_segments_misalignedSurfacesAreRejected() throws {
        let readView = makeReadView()
        let text = "今日は猫がいる"
        let badSegments: [SegmentRange] = [
            SegmentRange(surface: "今日"),
            SegmentRange(surface: "WRONG"),  // doesn't match text at this offset
            SegmentRange(surface: "猫がいる"),
        ]
        XCTAssertNil(readView.edgesFromSegmentRanges(badSegments, in: text),
            "Surface mismatch must yield nil so the caller falls back to fresh segmentation.")
    }

    // E2: furigana annotations embedded in SegmentRanges round-trip back to the
    // (location, length, reading) maps the renderer consumes. Run through both
    // directions: in-memory → SegmentRange → in-memory, and compare maps for equality.
    // Tests the full save/load cycle the renderer depends on.
    func test_furigana_roundTripsThroughSegmentAnnotations() throws {
        let readView = makeReadView()
        let text = "猫と犬"
        // Build edges directly so we know the exact UTF-16 layout.
        let edges: [LatticeEdge] = [
            LatticeEdge(
                start: text.index(text.startIndex, offsetBy: 0),
                end: text.index(text.startIndex, offsetBy: 1),
                surface: "猫"
            ),
            LatticeEdge(
                start: text.index(text.startIndex, offsetBy: 1),
                end: text.index(text.startIndex, offsetBy: 2),
                surface: "と"
            ),
            LatticeEdge(
                start: text.index(text.startIndex, offsetBy: 2),
                end: text.index(text.startIndex, offsetBy: 3),
                surface: "犬"
            ),
        ]

        // In-memory: 猫 → ねこ at location 0, 犬 → いぬ at location 2.
        let originalByLocation: [Int: String] = [0: "ねこ", 2: "いぬ"]
        let originalLengthByLocation: [Int: Int] = [0: 1, 2: 1]

        // Persist: build SegmentRanges with embedded annotations. Pass `in: text`
        // explicitly so buildSegmentRanges resolves edge indices against the same
        // string they were constructed from rather than the default empty `text`.
        let persisted = readView.buildSegmentRanges(
            from: edges,
            in: text,
            furiganaByLocation: originalByLocation,
            furiganaLengthByLocation: originalLengthByLocation
        )

        // Sanity: each persisted segment should carry only its own annotation.
        XCTAssertEqual(persisted.count, 3)
        XCTAssertEqual(persisted[0].furigana?.count, 1, "猫's segment should carry one annotation.")
        XCTAssertEqual(persisted[0].furigana?.first?.reading, "ねこ")
        XCTAssertNil(persisted[1].furigana, "と's segment has no kanji and no furigana.")
        XCTAssertEqual(persisted[2].furigana?.count, 1, "犬's segment should carry one annotation.")
        XCTAssertEqual(persisted[2].furigana?.first?.reading, "いぬ")

        // Load: reconstruct the in-memory maps from the persisted segments.
        let restored = readView.furiganaFromSegmentRanges(persisted)
        XCTAssertEqual(restored.byLocation, originalByLocation,
            "Reading map must round-trip exactly through SegmentRange persistence.")
        XCTAssertEqual(restored.lengthByLocation, originalLengthByLocation,
            "Length map must round-trip exactly through SegmentRange persistence.")
    }

    // E2 multi-run case: a compound segment (抜け殻) carrying TWO annotations (one
    // per kanji run) survives the round-trip with both annotations preserved AND
    // their absolute UTF-16 locations rebased correctly. This is where a naive
    // per-segment-start serializer would lose the second run.
    func test_furigana_multiRunCompoundRoundTrips() throws {
        let readView = makeReadView()
        let text = "抜け殻"
        let edges: [LatticeEdge] = [
            LatticeEdge(
                start: text.startIndex,
                end: text.endIndex,
                surface: "抜け殻"
            ),
        ]
        // Per-run annotations: 抜 → ぬ at location 0, 殻 → がら at location 2.
        let originalByLocation: [Int: String] = [0: "ぬ", 2: "がら"]
        let originalLengthByLocation: [Int: Int] = [0: 1, 2: 1]

        let persisted = readView.buildSegmentRanges(
            from: edges,
            in: text,
            furiganaByLocation: originalByLocation,
            furiganaLengthByLocation: originalLengthByLocation
        )
        XCTAssertEqual(persisted.first?.furigana?.count, 2,
            "Compound surface must persist BOTH per-run annotations, not just the first.")

        let restored = readView.furiganaFromSegmentRanges(persisted)
        XCTAssertEqual(restored.byLocation, originalByLocation)
        XCTAssertEqual(restored.lengthByLocation, originalLengthByLocation)
    }
}
