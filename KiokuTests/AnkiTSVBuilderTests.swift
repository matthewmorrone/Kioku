import XCTest
@testable import Kioku

// Pins the Anki import file: header lines, field cleanup, tags, and what a word contributes.
final class AnkiTSVBuilderTests: XCTestCase {
    func testBuildWritesHeaderAndOneLinePerRow() {
        let rows = [AnkiRow(front: "猫", back: "cat", reading: "ねこ", notes: "meow", tags: ["N5", "animals"])]
        let lines = AnkiTSVBuilder.build(rows: rows).components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(4)), ["#separator:tab", "#html:false", "#columns:Front\tBack\tReading\tNotes\tTags", "#tags column:5"])
        XCTAssertEqual(lines[4], "猫\tcat\tねこ\tmeow\tN5 animals")
        XCTAssertEqual(lines[5], "")
    }

    func testFieldsCannotBreakTheRow() {
        XCTAssertEqual(AnkiTSVBuilder.sanitized("a\tb\nc\r\nd "), "a b c d")
    }

    func testTagsReplaceSpaces() {
        XCTAssertEqual(AnkiTSVBuilder.tag(" Song  lyrics "), "Song_lyrics")
    }

    func testRowUsesCardContentAndPersonalNote() {
        let word = SavedWord(canonicalEntryID: 1, surface: "食べる", personalNote: "taberu")
        let content = WordCardContent(surface: "食べる", kanji: "食べる", kana: "たべる", meanings: ["to eat", "to consume"])
        let row = AnkiTSVBuilder.row(for: word, content: content, listNames: ["Verbs"])
        XCTAssertEqual(row, AnkiRow(front: "食べる", back: "to eat; to consume", reading: "たべる", notes: "taberu", tags: ["Verbs"]))
    }

    func testRowWithoutDictionaryKeepsSurfaceOnly() {
        let row = AnkiTSVBuilder.row(for: SavedWord(canonicalEntryID: 2, surface: "ねこ"), content: nil, listNames: [])
        XCTAssertEqual(row, AnkiRow(front: "ねこ", back: "", reading: "", notes: "", tags: []))
    }

    func testKanaOnlyWordDoesNotRepeatItselfAsReading() {
        let content = WordCardContent(surface: "ねこ", kanji: nil, kana: "ねこ", meanings: ["cat"])
        XCTAssertEqual(AnkiTSVBuilder.row(for: SavedWord(canonicalEntryID: 2, surface: "ねこ"), content: content, listNames: []).reading, "")
    }
}
