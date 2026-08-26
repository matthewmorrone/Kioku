import XCTest
@testable import Kioku

// Characterizes SongListenStore's pure state accessors: default values for a note that's
// never been rendered/played, and the read-after-write behavior of recordPosition. The
// render/retry pipeline itself dispatches into SongListenAudioService (real on-device TTS),
// which isn't invoked here for the same reason SongBreakdownStoreTests skips generation: it
// would need a protocol extraction on the service to mock cleanly, and exercising the real
// synthesizer isn't appropriate for a unit test.
@MainActor
final class SongListenStoreTests: XCTestCase {

    // A note that's never been touched reads as "just started rendering" rather than some
    // separate nil/unknown case — renderState(forNoteID:) folds "never requested" into the
    // same default a caller would show while waiting for ensureRendered's task to publish
    // its first progress update.
    func testRenderStateDefaultsToRenderingForUnknownNote() {
        let store = SongListenStore()
        XCTAssertEqual(store.renderState(forNoteID: UUID()), .rendering(progress: 0))
    }

    // cues(forNoteID:) is empty until a render actually completes and publishes something.
    func testCuesDefaultsToEmptyForUnknownNote() {
        let store = SongListenStore()
        XCTAssertTrue(store.cues(forNoteID: UUID()).isEmpty)
    }

    // lastPositionMs(forNoteID:) defaults to 0 (start of track) for a note that's never had
    // a position recorded.
    func testLastPositionDefaultsToZeroForUnknownNote() {
        let store = SongListenStore()
        XCTAssertEqual(store.lastPositionMs(forNoteID: UUID()), 0)
    }

    // recordPosition is a plain read-after-write: the next lastPositionMs(forNoteID:) call
    // for the same note reflects it, a later call overwrites rather than accumulates, and
    // it doesn't leak into other notes' entries.
    func testRecordPositionIsReadableByNoteIDAndScopedPerNote() {
        let store = SongListenStore()
        let id = UUID()
        let otherID = UUID()

        store.recordPosition(4200, forNoteID: id)

        XCTAssertEqual(store.lastPositionMs(forNoteID: id), 4200)
        XCTAssertEqual(store.lastPositionMs(forNoteID: otherID), 0)

        store.recordPosition(9000, forNoteID: id)
        XCTAssertEqual(store.lastPositionMs(forNoteID: id), 9000)
    }
}
