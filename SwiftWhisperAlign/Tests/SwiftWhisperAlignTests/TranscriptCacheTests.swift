// TranscriptCacheTests.swift
// Pins the resumable anchor-transcript checkpoint: the on-disk store that lets a jetsam/suspend
// kill mid-transcription resume from the last completed piece instead of redoing the ~60 s model
// load + every ASR piece. Verifies the content key isolates by region layout / piece size, the
// store→load roundtrip is exact, and clear() removes the entry.

import XCTest
@testable import SwiftWhisperAlign

final class TranscriptCacheTests: XCTestCase {

    // Unique per-test identity so concurrent/repeat runs never collide in the shared Caches dir.
    private func freshID() -> String { "test-\(UUID().uuidString)" }
    private let regions: [(start: Double, end: Double)] = [(0, 24), (24, 48), (48, 63)]
    private let pieceSec = 24.0

    override func tearDown() {
        super.tearDown()
        // Best-effort: tests below clear their own entries; this is a backstop.
    }

    func testStoreThenLoadRoundtrips() {
        let id = freshID()
        let pieces = [
            TranscriptCache.Piece(start: 0, end: 24, text: "ふっらいあなたの力になりたい"),
            TranscriptCache.Piece(start: 24, end: 48, text: "涙は頬を伝い"),
        ]
        TranscriptCache.store(pieces, identity: id, regions: regions, pieceSec: pieceSec)
        defer { TranscriptCache.clear(identity: id, regions: regions, pieceSec: pieceSec) }

        let loaded = TranscriptCache.load(identity: id, regions: regions, pieceSec: pieceSec)
        XCTAssertEqual(loaded, pieces)
    }

    // A different region layout (a re-VAD that moved a boundary) must NOT read the old transcript.
    func testRegionLayoutChangeMissesCache() {
        let id = freshID()
        let pieces = [TranscriptCache.Piece(start: 0, end: 24, text: "x")]
        TranscriptCache.store(pieces, identity: id, regions: regions, pieceSec: pieceSec)
        defer { TranscriptCache.clear(identity: id, regions: regions, pieceSec: pieceSec) }

        let shifted: [(start: Double, end: Double)] = [(0, 24), (24, 50), (50, 63)]   // moved boundary
        XCTAssertTrue(TranscriptCache.load(identity: id, regions: shifted, pieceSec: pieceSec).isEmpty)
        // Same layout still hits.
        XCTAssertEqual(TranscriptCache.load(identity: id, regions: regions, pieceSec: pieceSec), pieces)
    }

    // A different piece length lands on a fresh key.
    func testPieceSecChangeMissesCache() {
        let id = freshID()
        let pieces = [TranscriptCache.Piece(start: 0, end: 24, text: "x")]
        TranscriptCache.store(pieces, identity: id, regions: regions, pieceSec: pieceSec)
        defer {
            TranscriptCache.clear(identity: id, regions: regions, pieceSec: pieceSec)
            TranscriptCache.clear(identity: id, regions: regions, pieceSec: 30)
        }
        XCTAssertTrue(TranscriptCache.load(identity: id, regions: regions, pieceSec: 30).isEmpty)
    }

    // Incremental checkpoint: re-storing a longer list (next piece finished) overwrites cleanly.
    func testIncrementalCheckpointGrows() {
        let id = freshID()
        defer { TranscriptCache.clear(identity: id, regions: regions, pieceSec: pieceSec) }
        let p0 = TranscriptCache.Piece(start: 0, end: 24, text: "a")
        let p1 = TranscriptCache.Piece(start: 24, end: 48, text: "b")
        TranscriptCache.store([p0], identity: id, regions: regions, pieceSec: pieceSec)
        TranscriptCache.store([p0, p1], identity: id, regions: regions, pieceSec: pieceSec)
        XCTAssertEqual(TranscriptCache.load(identity: id, regions: regions, pieceSec: pieceSec), [p0, p1])
    }

    func testClearRemovesEntry() {
        let id = freshID()
        TranscriptCache.store([TranscriptCache.Piece(start: 0, end: 24, text: "x")],
                              identity: id, regions: regions, pieceSec: pieceSec)
        TranscriptCache.clear(identity: id, regions: regions, pieceSec: pieceSec)
        XCTAssertTrue(TranscriptCache.load(identity: id, regions: regions, pieceSec: pieceSec).isEmpty)
    }

    func testSignatureIsStableAndDistinct() {
        let a = TranscriptCache.signature(regions: regions, pieceSec: pieceSec)
        let b = TranscriptCache.signature(regions: regions, pieceSec: pieceSec)
        XCTAssertEqual(a, b, "signature must be deterministic across calls")
        let c = TranscriptCache.signature(regions: [(0, 24)], pieceSec: pieceSec)
        XCTAssertNotEqual(a, c, "different regions must yield a different signature")
    }
}
