import XCTest
@testable import Kioku

// Verifies note export includes token ranges from existing persisted/runtime state without recomputation.
@MainActor
final class NotesExportTests: XCTestCase {

    // Verifies export leaves token ranges empty when neither persisted overrides nor runtime snapshots exist.
    func testExportLeavesSegmentRangesEmptyWhenNoExistingSegmentationDataExists() {
        let store = NotesStore()
        store.notes = [
            Note(
                title: "Test",
                content: "abc",
                segments: nil,
                createdAt: Date(timeIntervalSince1970: 1),
                modifiedAt: Date(timeIntervalSince1970: 2)
            )
        ]

        let document = store.makeTransferDocument()
        let exportedRanges = document.payload.notes.first?.segments

        XCTAssertEqual(exportedRanges, [])
    }

    // Verifies export preserves existing token range overrides instead of replacing them.
    func testExportPreservesExistingSegmentRangesOverride() {
        let store = NotesStore()
        let overrideRanges = [SegmentRange(start: 0, end: 3)]
        store.notes = [
            Note(
                title: "Test",
                content: "abc",
                segments: overrideRanges,
                createdAt: Date(timeIntervalSince1970: 1),
                modifiedAt: Date(timeIntervalSince1970: 2)
            )
        ]

        let document = store.makeTransferDocument()
        let exportedRanges = document.payload.notes.first?.segments

        XCTAssertEqual(exportedRanges, overrideRanges)
    }

    // Verifies export prefers runtime segmentation when it matches the current note content.
    func testExportPrefersRuntimeSegmentationSnapshotWhenAvailable() {
        let store = NotesStore()
        let note = Note(
            id: UUID(),
            title: "Test",
            content: "abc",
            segments: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 2)
        )
        let runtimeRanges = [SegmentRange(start: 0, end: 1), SegmentRange(start: 1, end: 3)]

        store.notes = [note]
        store.recordRuntimeSegmentation(noteID: note.id, content: note.content, segments: runtimeRanges)

        let document = store.makeTransferDocument()
        let exportedRanges = document.payload.notes.first?.segments

        XCTAssertEqual(exportedRanges, runtimeRanges)
    }
}
