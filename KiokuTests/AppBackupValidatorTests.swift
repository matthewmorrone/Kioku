import XCTest
@testable import Kioku

@MainActor
final class AppBackupValidatorTests: XCTestCase {
    // Duplicate persistent identities must be rejected before restore constructs dictionaries.
    func testRejectsDuplicateNoteAndReviewIdentifiers() {
        let noteID = UUID()
        let note = Note(id: noteID, title: "A", content: "猫")
        let stats = AppBackupReviewStats(
            canonicalEntryID: 10,
            stats: ReviewWordStats(correct: 1, again: 0)
        )
        var payload = makePayload(notes: [note, note], reviewStats: [stats])

        XCTAssertThrowsError(try AppBackupValidator.validate(payload))

        payload.notes = [note]
        payload.reviewStats = [stats, stats]
        XCTAssertThrowsError(try AppBackupValidator.validate(payload))
    }

    // Persisted segmentation must provide exact, nonempty coverage and valid UTF-16 ruby ranges.
    func testRejectsInvalidPersistedSpanCoverageAndFurigana() {
        let badCoverage = Note(
            title: "Coverage",
            content: "猫です",
            segments: [SegmentRange(surface: "猫")]
        )
        XCTAssertThrowsError(try AppBackupValidator.validate(makePayload(notes: [badCoverage])))

        let badRuby = Note(
            title: "Ruby",
            content: "猫",
            segments: [
                SegmentRange(
                    surface: "猫",
                    furigana: [FuriganaAnnotation(start: 0, end: 2, reading: "ねこ")]
                )
            ]
        )
        XCTAssertThrowsError(try AppBackupValidator.validate(makePayload(notes: [badRuby])))
    }

    // Saved-word relationships must point to notes and lists contained in the same snapshot.
    func testRejectsBrokenSavedWordReferences() {
        let word = SavedWord(
            canonicalEntryID: 1,
            surface: "猫",
            sourceNoteIDs: [UUID()],
            wordListIDs: [UUID()]
        )

        XCTAssertThrowsError(try AppBackupValidator.validate(makePayload(words: [word])))
    }

    // A structurally consistent payload is admitted for transactional restore.
    func testAcceptsConsistentPayload() throws {
        let note = Note(
            title: "Valid",
            content: "猫です",
            segments: [SegmentRange(surface: "猫"), SegmentRange(surface: "です")]
        )
        let list = WordList(id: UUID(), name: "Animals", createdAt: Date())
        let word = SavedWord(
            canonicalEntryID: 1,
            surface: "猫",
            sourceNoteIDs: [note.id],
            wordListIDs: [list.id]
        )

        XCTAssertNoThrow(
            try AppBackupValidator.validate(
                makePayload(notes: [note], words: [word], wordLists: [list])
            )
        )
    }

    // Builds the smallest valid backup needed by each validation test.
    private func makePayload(
        notes: [Note] = [],
        words: [SavedWord] = [],
        wordLists: [WordList] = [],
        reviewStats: [AppBackupReviewStats] = []
    ) -> AppBackupPayload {
        AppBackupPayload(
            notes: notes,
            words: words,
            wordLists: wordLists,
            history: [],
            reviewStats: reviewStats,
            markedWrong: [],
            lifetimeCorrect: 0,
            lifetimeAgain: 0
        )
    }
}
