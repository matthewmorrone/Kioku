// LineAlignerTests.swift
// Validates LineAligner and SRTWriter against known reference output.
// Mock segments are derived from the stable-ts reference run on sample.wav.

import XCTest
@testable import WhisperKitAlign

final class LineAlignerTests: XCTestCase {

    // MARK: - Reference data from stable-ts align() on sample.wav

    let inputLines = [
        "今日はいい天気ですね。",
        "公園で散歩しましょう。",
        "花がきれいに咲いています。",
        "空は青くて雲が白い。",
        "夕方になると涼しくなります。",
    ]

    // Expected SRT timestamps from the stable-ts reference run.
    let expectedTimings: [(start: Double, end: Double)] = [
        (0.320, 1.840),
        (2.380, 4.340),
        (4.860, 6.760),
        (7.460, 9.660),
        (10.100, 12.380),
    ]

    // MARK: - Test 1: 1:1 segments (WhisperKit produces exactly one segment per line)

    func testOneToOneAlignment() {
        // Segments whose text matches each line exactly — easiest case.
        let segments = zip(inputLines, expectedTimings).map { line, t in
            TranscriptionSegment(text: line, start: t.start, end: t.end)
        }

        let result = LineAligner.align(lines: inputLines, segments: segments)

        XCTAssertEqual(result.count, inputLines.count)
        for (i, aligned) in result.enumerated() {
            XCTAssertEqual(aligned.text, inputLines[i], "line \(i) text mismatch")
            XCTAssertEqual(aligned.start, expectedTimings[i].start, accuracy: 0.001, "line \(i) start")
            XCTAssertEqual(aligned.end,   expectedTimings[i].end,   accuracy: 0.001, "line \(i) end")
        }
    }

    // MARK: - Test 2: Fewer segments than lines (DP must split/merge)

    func testFewerSegmentsThanLines() {
        // WhisperKit merges some lines into combined segments.
        // Lines 0+1 merged, lines 2+3 merged, line 4 alone.
        let segments: [TranscriptionSegment] = [
            TranscriptionSegment(text: "今日はいい天気ですね。公園で散歩しましょう。",
                                 start: 0.320, end: 4.340),
            TranscriptionSegment(text: "花がきれいに咲いています。空は青くて雲が白い。",
                                 start: 4.860, end: 9.660),
            TranscriptionSegment(text: "夕方になると涼しくなります。",
                                 start: 10.100, end: 12.380),
        ]

        let result = LineAligner.align(lines: inputLines, segments: segments)

        XCTAssertEqual(result.count, inputLines.count)

        // Lines 0 and 1 should both map to segment 0.
        XCTAssertEqual(result[0].start, 0.320, accuracy: 0.001)
        XCTAssertEqual(result[0].end,   4.340, accuracy: 0.001)
        XCTAssertEqual(result[1].start, 0.320, accuracy: 0.001)
        XCTAssertEqual(result[1].end,   4.340, accuracy: 0.001)

        // Lines 2 and 3 should both map to segment 1.
        XCTAssertEqual(result[2].start, 4.860, accuracy: 0.001)
        XCTAssertEqual(result[2].end,   9.660, accuracy: 0.001)
        XCTAssertEqual(result[3].start, 4.860, accuracy: 0.001)
        XCTAssertEqual(result[3].end,   9.660, accuracy: 0.001)

        // Line 4 maps to segment 2.
        XCTAssertEqual(result[4].start, 10.100, accuracy: 0.001)
        XCTAssertEqual(result[4].end,   12.380, accuracy: 0.001)
    }

    // MARK: - Test 3: More segments than lines (DP must span multiple segments per line)

    func testMoreSegmentsThanLines() {
        // WhisperKit splits some lines further.
        let segments: [TranscriptionSegment] = [
            TranscriptionSegment(text: "今日は",        start: 0.320, end: 0.900),
            TranscriptionSegment(text: "いい天気ですね。", start: 0.900, end: 1.840),
            TranscriptionSegment(text: "公園で散歩しましょう。", start: 2.380, end: 4.340),
            TranscriptionSegment(text: "花がきれいに咲いています。", start: 4.860, end: 6.760),
            TranscriptionSegment(text: "空は青くて雲が白い。",   start: 7.460, end: 9.660),
            TranscriptionSegment(text: "夕方になると涼しくなります。", start: 10.100, end: 12.380),
        ]

        let result = LineAligner.align(lines: inputLines, segments: segments)

        XCTAssertEqual(result.count, inputLines.count)

        // Line 0 should span segments 0+1 → start=0.320, end=1.840.
        XCTAssertEqual(result[0].start, 0.320, accuracy: 0.001)
        XCTAssertEqual(result[0].end,   1.840, accuracy: 0.001)

        // Lines 1-4 each get one segment.
        XCTAssertEqual(result[1].start, 2.380, accuracy: 0.001)
        XCTAssertEqual(result[1].end,   4.340, accuracy: 0.001)
        XCTAssertEqual(result[2].start, 4.860, accuracy: 0.001)
        XCTAssertEqual(result[4].end,   12.380, accuracy: 0.001)
    }

    // MARK: - Test 4: SRT output format matches stable-ts reference exactly

    func testSRTFormat() {
        let segments = zip(inputLines, expectedTimings).map { line, t in
            TranscriptionSegment(text: line, start: t.start, end: t.end)
        }
        let aligned = LineAligner.align(lines: inputLines, segments: segments)
        let result  = AlignmentResult(lines: aligned)
        let srt     = SRTWriter.write(result)

        let expected = """
1
00:00:00,320 --> 00:00:01,840
今日はいい天気ですね。

2
00:00:02,380 --> 00:00:04,340
公園で散歩しましょう。

3
00:00:04,860 --> 00:00:06,760
花がきれいに咲いています。

4
00:00:07,460 --> 00:00:09,660
空は青くて雲が白い。

5
00:00:10,100 --> 00:00:12,380
夕方になると涼しくなります。

"""
        XCTAssertEqual(srt, expected)
    }

    // MARK: - Test 5: SRTWriter timestamp formatting edge cases

    func testTimestampFormatting() {
        XCTAssertEqual(SRTWriter.timestamp(0.0),     "00:00:00,000")
        XCTAssertEqual(SRTWriter.timestamp(1.5),     "00:00:01,500")
        XCTAssertEqual(SRTWriter.timestamp(59.999),  "00:00:59,999")
        XCTAssertEqual(SRTWriter.timestamp(60.0),    "00:01:00,000")
        XCTAssertEqual(SRTWriter.timestamp(3661.001),"01:01:01,001")
    }
}
