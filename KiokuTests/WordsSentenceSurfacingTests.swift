import XCTest
@testable import Kioku

// Pins WordsView.shouldSurfaceSentences — the rule that folds the old standalone
// "Search Example Sentences" tool into the main search. Inline sentences should appear
// only when they add something the word detail's own examples section doesn't.
final class WordsSentenceSurfacingTests: XCTestCase {

    // No corpus matches ⇒ never show the section, regardless of query shape.
    func testNoSentencesNeverSurfaces() {
        XCTAssertFalse(WordsView.shouldSurfaceSentences(
            query: "I have to go", entryCount: 0, sentenceCount: 0, hasParsedSegments: true))
    }

    // A multi-token Japanese phrase (parsed into segments) is exactly the whole-phrase
    // lookup the standalone tool existed for.
    func testParsedJapanesePhraseSurfaces() {
        XCTAssertTrue(WordsView.shouldSurfaceSentences(
            query: "雨が降る", entryCount: 0, sentenceCount: 5, hasParsedSegments: true))
    }

    // A space-separated / English phrase surfaces even when entry FTS returned plenty of
    // single-word hits — you can't reach those sentences by opening one entry.
    func testEnglishPhraseSurfacesDespiteManyEntries() {
        XCTAssertTrue(WordsView.shouldSurfaceSentences(
            query: "I have to go", entryCount: 40, sentenceCount: 12, hasParsedSegments: false))
    }

    // A plain single word with plenty of entries stays clean — its examples live one tap
    // away in the word detail, so an inline section would just be redundant clutter.
    func testCommonSingleWordDoesNotSurface() {
        XCTAssertFalse(WordsView.shouldSurfaceSentences(
            query: "language", entryCount: 20, sentenceCount: 30, hasParsedSegments: false))
    }

    // A single word whose entry matches are sparse falls through to sentences.
    func testSparseEntryMatchesSurface() {
        XCTAssertTrue(WordsView.shouldSurfaceSentences(
            query: "rareword", entryCount: 1, sentenceCount: 3, hasParsedSegments: false))
        XCTAssertTrue(WordsView.shouldSurfaceSentences(
            query: "edge", entryCount: 2, sentenceCount: 3, hasParsedSegments: false))
        XCTAssertFalse(WordsView.shouldSurfaceSentences(
            query: "edge", entryCount: 3, sentenceCount: 3, hasParsedSegments: false))
    }
}
