import XCTest
@testable import Kioku

// Verifies the short-form TextGrid parser against synthetic fixtures and the structural shape
// expected from typical forced-aligner output (silence intervals + non-empty intervals + multiple tiers).
@MainActor
final class TextGridParserTests: XCTestCase {

    private let header = """
    File type = "ooTextFile"
    Object class = "TextGrid"

    0
    177.396
    <exists>
    """

    func testParsesSingleTierOneInterval() throws {
        let content = header + """

        1
        "IntervalTier"
        "words"
        0
        177.396
        1
        0.0
        1.234
        "ご"

        """
        let grid = try TextGridParser.parse(content)
        XCTAssertEqual(grid.durationMs, 177_396)
        XCTAssertEqual(grid.tiers.count, 1)
        XCTAssertEqual(grid.tiers[0].name, "words")
        XCTAssertEqual(grid.tiers[0].intervals.count, 1)
        XCTAssertEqual(grid.tiers[0].intervals[0].startMs, 0)
        XCTAssertEqual(grid.tiers[0].intervals[0].endMs, 1_234)
        XCTAssertEqual(grid.tiers[0].intervals[0].text, "ご")
    }

    func testParsesTwoTiersWithSilenceIntervals() throws {
        let content = header + """

        2
        "IntervalTier"
        "segments"
        0
        177.396
        2
        0
        18.64
        ""
        18.64
        18.86
        "ごめんね素直じゃなくて"
        "IntervalTier"
        "words"
        0
        177.396
        3
        0
        18.64
        ""
        18.64
        18.68
        "ご"
        18.68
        18.7
        "め"

        """
        let grid = try TextGridParser.parse(content)
        XCTAssertEqual(grid.tiers.count, 2)
        XCTAssertEqual(grid.tiers[0].name, "segments")
        XCTAssertEqual(grid.tiers[0].intervals.count, 2)
        XCTAssertEqual(grid.tiers[0].intervals[0].text, "")
        XCTAssertEqual(grid.tiers[0].intervals[1].text, "ごめんね素直じゃなくて")
        XCTAssertEqual(grid.tiers[1].name, "words")
        XCTAssertEqual(grid.tiers[1].intervals.count, 3)
        XCTAssertEqual(grid.tiers[1].intervals[2].text, "め")
    }

    func testRoundsTimesToNearestMillisecond() throws {
        let content = header + """

        1
        "IntervalTier"
        "t"
        0
        1.0
        1
        0.0
        0.0005
        "x"

        """
        let grid = try TextGridParser.parse(content)
        XCTAssertEqual(grid.tiers[0].intervals[0].endMs, 1)
    }

    func testHandlesEscapedDoubleQuotesInLabels() throws {
        // Raw multi-line string (#"""..."""#) lets us embed the literal `"""` sequence that Praat's
        // `""`-escape produces at end-of-label without Swift treating it as the closing delimiter.
        let content = header + #"""


        1
        "IntervalTier"
        "t"
        0
        1.0
        1
        0.0
        1.0
        "she said ""hi"""

        """#
        let grid = try TextGridParser.parse(content)
        XCTAssertEqual(grid.tiers[0].intervals[0].text, "she said \"hi\"")
    }

    func testThrowsOnTruncatedInput() {
        let content = header + """

        2
        "IntervalTier"
        "only"
        0
        1.0
        0

        """
        XCTAssertThrowsError(try TextGridParser.parse(content))
    }

    func testRejectsLongFormSyntax() {
        let content = """
        File type = "ooTextFile"
        Object class = "TextGrid"

        xmin = 0
        xmax = 1
        tiers? <exists>
        size = 0
        item []:
        """
        XCTAssertThrowsError(try TextGridParser.parse(content))
    }

    func testParsesPointTierAsEmptyInterval() throws {
        let content = header + """

        1
        "TextTier"
        "events"
        0
        1.0
        0

        """
        let grid = try TextGridParser.parse(content)
        XCTAssertEqual(grid.tiers.count, 1)
        XCTAssertEqual(grid.tiers[0].name, "events")
        XCTAssertEqual(grid.tiers[0].intervals.count, 0)
    }

    // Round-trips a fixture lifted from the user's ムーンライト伝説.TextGrid (truncated to the first
    // few intervals of each tier). Asserts the parser handles real forced-aligner output structure.
    func testParsesRealWorldFixture() throws {
        let content = """
        File type = "ooTextFile"
        Object class = "TextGrid"

        0
        177.396
        <exists>
        2
        "IntervalTier"
        "segments"
        0
        177.396
        3
        0
        18.64
        ""
        18.64
        18.86
        "ごめんね素直じゃなくて"
        18.86
        18.92
        "思考回路はショート寸前"
        "IntervalTier"
        "words"
        0
        177.396
        4
        0
        18.64
        ""
        18.64
        18.68
        "ご"
        18.68
        18.7
        "め"
        18.7
        18.86
        "ん"

        """
        let grid = try TextGridParser.parse(content)
        XCTAssertEqual(grid.tiers.map(\.name), ["segments", "words"])
        XCTAssertEqual(grid.tiers[0].intervals.last?.text, "思考回路はショート寸前")
        XCTAssertEqual(grid.tiers[1].intervals.count, 4)
        XCTAssertEqual(grid.tiers[1].intervals[3].text, "ん")
    }
}
