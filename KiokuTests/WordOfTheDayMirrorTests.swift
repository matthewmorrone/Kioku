import XCTest
@testable import Kioku

// Exercises the pure selection, serialization, and deep-link logic that backs the Word of the Day
// widget. These avoid the App Group store so they run without entitlements.
final class WordOfTheDayMirrorTests: XCTestCase {
    private func entry(_ offsetSeconds: TimeInterval, id: Int64) -> WordOfTheDayMirrorEntry {
        WordOfTheDayMirrorEntry(
            fireDate: Date(timeIntervalSinceReferenceDate: offsetSeconds),
            surface: "語\(id)",
            kana: "ご",
            meaning: "word \(id)",
            entryID: id
        )
    }

    // MARK: - mostRecentEntry

    func testMostRecentReturnsNilForEmptyMirror() {
        XCTAssertNil(WordOfTheDayMirror.mostRecentEntry(in: [], asOf: Date()))
    }

    func testMostRecentReturnsNilWhenAllEntriesAreInTheFuture() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let entries = [entry(200, id: 1), entry(300, id: 2)]
        XCTAssertNil(WordOfTheDayMirror.mostRecentEntry(in: entries, asOf: now))
    }

    func testMostRecentPicksLatestEntryNotInFuture() {
        let now = Date(timeIntervalSinceReferenceDate: 250)
        // Deliberately unsorted to prove selection does not rely on input order.
        let entries = [entry(300, id: 3), entry(100, id: 1), entry(200, id: 2)]
        let result = WordOfTheDayMirror.mostRecentEntry(in: entries, asOf: now)
        XCTAssertEqual(result?.entryID, 2)
    }

    func testMostRecentIncludesEntryExactlyAtNow() {
        let now = Date(timeIntervalSinceReferenceDate: 200)
        let entries = [entry(100, id: 1), entry(200, id: 2)]
        let result = WordOfTheDayMirror.mostRecentEntry(in: entries, asOf: now)
        XCTAssertEqual(result?.entryID, 2)
    }

    func testMostRecentAfterLastFireReturnsLastEntry() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let entries = [entry(100, id: 1), entry(200, id: 2), entry(300, id: 3)]
        let result = WordOfTheDayMirror.mostRecentEntry(in: entries, asOf: now)
        XCTAssertEqual(result?.entryID, 3)
    }

    // MARK: - Serialization

    func testMirrorEntriesRoundTripThroughCodable() throws {
        let original = [entry(100, id: 1), entry(200, id: 2)]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([WordOfTheDayMirrorEntry].self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Deep link

    func testDeepLinkURLRoundTrips() throws {
        let url = try XCTUnwrap(WordOfTheDayMirror.deepLinkURL(entryID: 123, surface: "勉強"))
        let parsed = try XCTUnwrap(WordOfTheDayMirror.parseDeepLink(url))
        XCTAssertEqual(parsed.entryID, 123)
        XCTAssertEqual(parsed.surface, "勉強")
    }

    func testParseDeepLinkRejectsWrongScheme() throws {
        let url = try XCTUnwrap(URL(string: "https://word?id=1&surface=x"))
        XCTAssertNil(WordOfTheDayMirror.parseDeepLink(url))
    }

    func testParseDeepLinkRejectsMissingID() throws {
        let url = try XCTUnwrap(URL(string: "kioku://word?surface=x"))
        XCTAssertNil(WordOfTheDayMirror.parseDeepLink(url))
    }

    func testParseDeepLinkAllowsMissingSurface() throws {
        let url = try XCTUnwrap(URL(string: "kioku://word?id=42"))
        let parsed = try XCTUnwrap(WordOfTheDayMirror.parseDeepLink(url))
        XCTAssertEqual(parsed.entryID, 42)
        XCTAssertNil(parsed.surface)
    }
}
