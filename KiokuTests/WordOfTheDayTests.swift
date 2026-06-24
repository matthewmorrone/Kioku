import XCTest
@testable import Kioku

// Exercises the deterministic date→word logic, snapshot serialization, and deep-link parsing that
// back the Word of the Day widget. All pure, so they run without the App Group store.
final class WordOfTheDayTests: XCTestCase {
    // Fixed UTC calendar so hour-based assertions are independent of the test machine's time zone.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return calendar.date(from: components)!
    }

    private func words(_ count: Int) -> [WordOfTheDayWord] {
        (0..<count).map { WordOfTheDayWord(entryID: Int64($0), surface: "語\($0)", kana: "ご", meaning: "word \($0)") }
    }

    // MARK: - dayNumber

    func testDayNumberIncrementsByOnePerCalendarDay() {
        let a = WordOfTheDay.dayNumber(for: date(2026, 6, 24, 9), calendar: calendar)
        let b = WordOfTheDay.dayNumber(for: date(2026, 6, 25, 9), calendar: calendar)
        XCTAssertEqual(b - a, 1)
    }

    func testDayNumberIgnoresTimeOfDay() {
        let morning = WordOfTheDay.dayNumber(for: date(2026, 6, 24, 1), calendar: calendar)
        let evening = WordOfTheDay.dayNumber(for: date(2026, 6, 24, 23), calendar: calendar)
        XCTAssertEqual(morning, evening)
    }

    // MARK: - word(forDayNumber:)

    func testWordRotatesModuloCount() {
        let list = words(3)
        XCTAssertEqual(WordOfTheDay.word(forDayNumber: 0, in: list)?.entryID, 0)
        XCTAssertEqual(WordOfTheDay.word(forDayNumber: 3, in: list)?.entryID, 0)
        XCTAssertEqual(WordOfTheDay.word(forDayNumber: 4, in: list)?.entryID, 1)
    }

    func testWordHandlesNegativeDayNumbers() {
        let list = words(3)
        XCTAssertEqual(WordOfTheDay.word(forDayNumber: -1, in: list)?.entryID, 2)
    }

    func testWordReturnsNilForEmptyList() {
        XCTAssertNil(WordOfTheDay.word(forDayNumber: 5, in: []))
    }

    // MARK: - effectiveDayNumber / currentWord rollover

    func testEffectiveDayIsYesterdayBeforeFireTime() {
        let now = date(2026, 6, 24, 8) // 08:00, fire time 09:00 → not fired yet
        let effective = WordOfTheDay.effectiveDayNumber(asOf: now, hour: 9, minute: 0, calendar: calendar)
        XCTAssertEqual(effective, WordOfTheDay.dayNumber(for: now, calendar: calendar) - 1)
    }

    func testEffectiveDayIsTodayAtAndAfterFireTime() {
        let now = date(2026, 6, 24, 9) // exactly 09:00
        let effective = WordOfTheDay.effectiveDayNumber(asOf: now, hour: 9, minute: 0, calendar: calendar)
        XCTAssertEqual(effective, WordOfTheDay.dayNumber(for: now, calendar: calendar))
    }

    func testCurrentWordRollsOverAtFireTime() {
        let list = words(5)
        let snapshot = WordOfTheDaySnapshot(enabled: true, hour: 9, minute: 0, words: list)
        let before = WordOfTheDay.currentWord(asOf: date(2026, 6, 24, 8), snapshot: snapshot, calendar: calendar)
        let after = WordOfTheDay.currentWord(asOf: date(2026, 6, 24, 9), snapshot: snapshot, calendar: calendar)

        let today = WordOfTheDay.dayNumber(for: date(2026, 6, 24, 9), calendar: calendar)
        XCTAssertEqual(before?.entryID, WordOfTheDay.word(forDayNumber: today - 1, in: list)?.entryID)
        XCTAssertEqual(after?.entryID, WordOfTheDay.word(forDayNumber: today, in: list)?.entryID)
        XCTAssertNotEqual(before?.entryID, after?.entryID)
    }

    func testCurrentWordNilWhenDisabled() {
        let snapshot = WordOfTheDaySnapshot(enabled: false, hour: 9, minute: 0, words: words(3))
        XCTAssertNil(WordOfTheDay.currentWord(asOf: date(2026, 6, 24, 12), snapshot: snapshot, calendar: calendar))
    }

    func testCurrentWordNilWhenNoWords() {
        let snapshot = WordOfTheDaySnapshot(enabled: true, hour: 9, minute: 0, words: [])
        XCTAssertNil(WordOfTheDay.currentWord(asOf: date(2026, 6, 24, 12), snapshot: snapshot, calendar: calendar))
    }

    // MARK: - nextFireDate

    func testNextFireDateIsStrictlyAfterAtTheConfiguredTime() {
        let next = try? XCTUnwrap(WordOfTheDay.nextFireDate(after: date(2026, 6, 24, 8), hour: 9, minute: 0, calendar: calendar))
        let components = calendar.dateComponents([.hour, .minute], from: next!)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 0)
        XCTAssertGreaterThan(next!, date(2026, 6, 24, 8))
    }

    func testNextFireDateRollsToTomorrowWhenTodaysTimePassed() {
        let next = WordOfTheDay.nextFireDate(after: date(2026, 6, 24, 10), hour: 9, minute: 0, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.day], from: next!).day, 25)
    }

    // MARK: - Snapshot serialization

    func testSnapshotRoundTripsThroughCodable() throws {
        let original = WordOfTheDaySnapshot(enabled: true, hour: 7, minute: 30, words: words(4))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WordOfTheDaySnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Deep link

    func testDeepLinkURLRoundTrips() throws {
        let url = try XCTUnwrap(WordOfTheDay.deepLinkURL(entryID: 123, surface: "勉強"))
        let parsed = try XCTUnwrap(WordOfTheDay.parseDeepLink(url))
        XCTAssertEqual(parsed.entryID, 123)
        XCTAssertEqual(parsed.surface, "勉強")
    }

    func testParseDeepLinkRejectsWrongScheme() throws {
        let url = try XCTUnwrap(URL(string: "https://word?id=1&surface=x"))
        XCTAssertNil(WordOfTheDay.parseDeepLink(url))
    }

    func testParseDeepLinkRejectsMissingID() throws {
        let url = try XCTUnwrap(URL(string: "kioku://word?surface=x"))
        XCTAssertNil(WordOfTheDay.parseDeepLink(url))
    }

    func testParseDeepLinkAllowsMissingSurface() throws {
        let url = try XCTUnwrap(URL(string: "kioku://word?id=42"))
        let parsed = try XCTUnwrap(WordOfTheDay.parseDeepLink(url))
        XCTAssertEqual(parsed.entryID, 42)
        XCTAssertNil(parsed.surface)
    }
}
