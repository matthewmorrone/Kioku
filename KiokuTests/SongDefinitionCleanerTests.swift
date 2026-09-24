import XCTest
@testable import Kioku

// Characterizes SongDefinitionCleaner on definitions taken from real breakdowns: commentary is
// cut after a semicolon, the first sentence, or a spaced em dash; double quotes go; and a
// back-reference prefix is dropped unless it's all there is.
@MainActor
final class SongDefinitionCleanerTests: XCTestCase {

    // Commentary after the gloss's first sentence is cut, with no semicolon involved.
    func testCutsAtFirstSentenceEnd() {
        XCTAssertEqual(
            SongDefinitionCleaner.clean("adverbial form of 儚い, meaning fleeting or transient. Carries the sense of something that vanishes before you can hold it."),
            "adverbial form of 儚い, meaning fleeting or transient"
        )
    }

    // A sentence that ends inside a quote still ends the gloss.
    func testSentenceEndingInsideQuoteStillCuts() {
        XCTAssertEqual(
            SongDefinitionCleaner.clean(#""knocks on the door." The premonition itself is personified as something knocking."#),
            "knocks on the door"
        )
    }

    // The semicolon cut still applies.
    func testCutsAtSemicolon() {
        XCTAssertEqual(
            SongDefinitionCleaner.clean("wind; one of the song's central natural agents, personified as carrying things"),
            "wind"
        )
    }

    // A spaced em dash introduces commentary too.
    func testCutsAtSpacedEmDash() {
        XCTAssertEqual(
            SongDefinitionCleaner.clean("to swim — used metaphorically, the heart drifted"),
            "to swim"
        )
    }

    // Double quotes around glosses are dropped, straight or curly.
    func testRemovesDoubleQuotes() {
        XCTAssertEqual(
            SongDefinitionCleaner.clean(#"particle marking the trigger: "in response to," “upon”"#),
            "particle marking the trigger: in response to, upon"
        )
    }

    // An abbreviation's period isn't a sentence end.
    func testAbbreviationDoesNotEndTheGloss() {
        XCTAssertEqual(
            SongDefinitionCleaner.clean("a flower, e.g. a cherry blossom. Evokes spring."),
            "a flower, e.g. a cherry blossom"
        )
    }

    // A leading back-reference is dropped; one that is the whole definition is kept.
    func testBackReferencePrefix() {
        XCTAssertEqual(SongDefinitionCleaner.clean("= line 4. Just like this, unchanged."), "Just like this, unchanged")
        XCTAssertEqual(SongDefinitionCleaner.clean("as in line 8."), "as in line 8")
    }

    // Apostrophes are words, not quotes.
    func testKeepsApostrophes() {
        XCTAssertEqual(SongDefinitionCleaner.clean("can't bring myself to smile"), "can't bring myself to smile")
    }
}
