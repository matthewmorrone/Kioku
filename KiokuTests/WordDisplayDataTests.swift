import XCTest
@testable import Kioku

final class WordDisplayDataTests: XCTestCase {
    var store: DictionaryStore!

    override func setUpWithError() throws {
        store = try DictionaryStore()
    }

    // fetchWordDisplayData for a known word returns a non-nil result with senses.
    func testKnownWordReturnsData() throws {
        let entries = try store.lookup(surface: "学校", mode: .kanjiAndKana)
        let first = try XCTUnwrap(entries.first)
        let data = try store.fetchWordDisplayData(entryID: first.entryId, surface: "学校")
        XCTAssertNotNil(data)
        XCTAssertFalse(data!.entry.senses.isEmpty)
    }

    // fetchWordDisplayData for a nonexistent entry ID returns nil without throwing.
    func testUnknownEntryIDReturnsNil() throws {
        let data = try store.fetchWordDisplayData(entryID: -1, surface: "x")
        XCTAssertNil(data)
    }

    // fetchWordDisplayData returns the same entry as lookupEntry for the same ID.
    func testEntryMatchesLookupEntry() throws {
        let entries = try store.lookup(surface: "食べる", mode: .kanjiAndKana)
        let first = try XCTUnwrap(entries.first)
        let data = try XCTUnwrap(try store.fetchWordDisplayData(entryID: first.entryId, surface: "食べる"))
        let direct = try XCTUnwrap(try store.lookupEntry(entryID: first.entryId))
        XCTAssertEqual(data.entry.entryId, direct.entryId)
        XCTAssertEqual(data.entry.senses.count, direct.senses.count)
    }
}
