import XCTest
@testable import Kioku

// Verifies SavedWord.reconcilingStableKey — the pure logic that keeps a saved card anchored to the
// stable JMdict ent_seq instead of the rebuild-unstable entries.id row id. The two dictionary
// lookups are injected as closures, so no database is needed.
final class SavedWordStableKeyTests: XCTestCase {
    private func word(canonicalEntryID: Int64, entSeq: Int64?) -> SavedWord {
        SavedWord(canonicalEntryID: canonicalEntryID, surface: "日", entSeq: entSeq)
    }

    // Legacy card (no ent_seq) gets ent_seq backfilled from its current row id; the id is untouched.
    func testLegacyCardBackfillsEntSeq() {
        let migrated = word(canonicalEntryID: 43355, entSeq: nil).reconcilingStableKey(
            entSeqForEntryID: { $0 == 43355 ? 1463770 : nil },
            entryIDForEntSeq: { _ in nil }
        )
        XCTAssertEqual(migrated.entSeq, 1463770)
        XCTAssertEqual(migrated.canonicalEntryID, 43355)
    }

    // A card with a known ent_seq re-resolves its row id — this is the drift correction across a
    // rebuild (43355 → 43360 for the same ent_seq).
    func testKnownEntSeqReresolvesRowID() {
        let migrated = word(canonicalEntryID: 43355, entSeq: 1463770).reconcilingStableKey(
            entSeqForEntryID: { _ in nil },
            entryIDForEntSeq: { $0 == 1463770 ? 43360 : nil }
        )
        XCTAssertEqual(migrated.canonicalEntryID, 43360)
        XCTAssertEqual(migrated.entSeq, 1463770)
    }

    // No change when the ent_seq already resolves to the current row id → returns self unchanged.
    func testNoOpWhenAlreadyCurrent() {
        let original = word(canonicalEntryID: 43355, entSeq: 1463770)
        let migrated = original.reconcilingStableKey(
            entSeqForEntryID: { _ in nil },
            entryIDForEntSeq: { _ in 43355 }
        )
        XCTAssertEqual(migrated, original)
        XCTAssertEqual(migrated.canonicalEntryID, 43355)
        XCTAssertEqual(migrated.entSeq, 1463770)
    }

    // If the ent_seq no longer exists in this build, keep the last-known row id rather than nuking it.
    func testUnresolvableEntSeqKeepsCurrentID() {
        let migrated = word(canonicalEntryID: 43355, entSeq: 9_999_999).reconcilingStableKey(
            entSeqForEntryID: { _ in nil },
            entryIDForEntSeq: { _ in nil }
        )
        XCTAssertEqual(migrated.canonicalEntryID, 43355)
    }

    // A legacy card whose current id isn't in the dictionary stays as-is (nothing to anchor to).
    func testLegacyCardWithUnknownIDUnchanged() {
        let original = word(canonicalEntryID: 1, entSeq: nil)
        let migrated = original.reconcilingStableKey(
            entSeqForEntryID: { _ in nil },
            entryIDForEntSeq: { _ in nil }
        )
        XCTAssertEqual(migrated, original)
        XCTAssertNil(migrated.entSeq)
    }
}
