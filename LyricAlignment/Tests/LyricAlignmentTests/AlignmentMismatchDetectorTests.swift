// AlignmentMismatchDetectorTests.swift
// Pins AlignmentMismatchDetector's two rules on the cases that set their thresholds: 乙女のススメ's
// 20 s gap over sung audio and its stretched なりたいあたし line (flagged), and the false alarms
// measured on the phone's songs (held notes either side of an interlude, a slow held line, a word
// parked past its line's end), which must stay quiet.

import XCTest
@testable import LyricAlignment

final class AlignmentMismatchDetectorTests: XCTestCase {

    // One romanized span per mora-sized chunk, which is all the detector reads.
    private func spans(_ romaji: String) -> [RomanizedSpan] {
        romaji.split(separator: "|").map { RomanizedSpan(romaji: String($0), charOffsetUTF16: 0, charLengthUTF16: 1) }
    }

    // Word starts spread evenly from `start` to `last`.
    private func tokens(_ count: Int, from start: Double, to last: Double) -> [AlignedToken] {
        (0..<count).map { AlignedToken(start: start + (last - start) * Double($0) / Double(max(1, count - 1)), charOffsetUTF16: $0, charLengthUTF16: 1) }
    }

    // Singing with no line inside one sung region is flagged, from where the singing starts.
    func testSingingWithNoLineIsFlagged() {
        let lines = [AlignedLine(text: "a", start: 22.0, end: 32.4), AlignedLine(text: "b", start: 52.6, end: 60.0)]
        let found = AlignmentMismatchDetector.detect(
            lines: lines, lineTokens: [tokens(5, from: 22, to: 31), tokens(5, from: 52.6, to: 58)],
            romanization: [spans("a|i|u|e|o|ka|ki|ku|ke|ko|sa|shi|su|se|so"), spans("a|i|u|e|o|ka|ki|ku|ke|ko|sa|shi|su|se|so")],
            regions: [(21, 34), (37, 110)], stem: nil, durationSec: 60)
        XCTAssertEqual(found, [AlignmentMismatch(kind: .unmatchedSinging, start: 37, end: 52.6, lineIndex: 1)])
    }

    // Held notes trailing into an interlude and leading out of it are separate regions and never add up.
    func testHeldNotesEitherSideOfAnInterludeStayQuiet() {
        let lines = [AlignedLine(text: "a", start: 157.8, end: 162.4), AlignedLine(text: "b", start: 186.4, end: 193.5)]
        let found = AlignmentMismatchDetector.detect(
            lines: lines, lineTokens: [tokens(4, from: 157.8, to: 162), tokens(4, from: 186.4, to: 193)],
            romanization: [spans("so|no|shunkan|o|ima|tomo|ni|futari|de"), spans("taiyou|ga|shizu|mi|sekai|no|o|wa|ri|ga")],
            regions: [(156, 165), (183, 234)], stem: nil, durationSec: 193.5)
        XCTAssertEqual(found, [])
    }

    // A line whose words are spread far slower than they can be sung is flagged.
    func testStretchedLineIsFlagged() {
        let lines = [AlignedLine(text: "なりたいあたし　会いたいあたし", start: 52.57, end: 67.84)]
        let found = AlignmentMismatchDetector.detect(
            lines: lines, lineTokens: [tokens(14, from: 52.57, to: 67.66)],
            romanization: [spans("na|ri|ta|i|a|ta|shi|a|i|ta|i|a|ta|shi")],
            regions: [(52, 110)], stem: nil, durationSec: 70)
        XCTAssertEqual(found, [AlignmentMismatch(kind: .stretchedLine, start: 52.57, end: 67.84, lineIndex: 0)])
    }

    // A slow line whose end is only bridged to the next line, and a line with one word parked past
    // its end, are measured by their sung words and stay quiet.
    func testHeldLineAndParkedWordStayQuiet() {
        let lines = [AlignedLine(text: "a", start: 73.67, end: 81.70), AlignedLine(text: "b", start: 194.44, end: 205.02)]
        let parked = tokens(8, from: 194.44, to: 198.02) + [AlignedToken(start: 212.2, charOffsetUTF16: 8, charLengthUTF16: 1)]
        let found = AlignmentMismatchDetector.detect(
            lines: lines, lineTokens: [tokens(7, from: 73.67, to: 77.45), parked],
            romanization: [spans("uta|i|tsuzu|ke|te|yu|ku"), spans("tenshi|no|hane|de|to|bi|ta|tsu|no")],
            regions: [(73, 82), (194, 206)], stem: nil, durationSec: 230)
        XCTAssertEqual(found, [])
    }
}
