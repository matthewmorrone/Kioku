import XCTest
import SwiftWhisperAlign
@testable import Kioku

// Pins the Swift CTC Viterbi to torchaudio's forced_align on real emissions: the fixture is
// the CoreML MMS aligner's log-probabilities for the tsukiiro-chainon vocal stem (with the
// frames outside the sung regions pinned to blank, exactly as CTCForcedAligner does) and the
// per-word start/end frames torchaudio produced for the same romanized words. The DP is the
// one piece of the aligner that has an exact reference, so it's held frame-exact here.
final class CTCViterbiFixtureTests: XCTestCase {
    private struct Expected: Decodable {
        let labels: [String]
        let frames: Int
        let frameSec: Double
        let words: [String]
        let regions: [[Double]]
        let wordStartFrames: [Int]
        let wordEndFrames: [Int]
    }

    func testViterbiMatchesTorchaudioOnRealEmissions() throws {
        let bundle = Bundle(for: type(of: self))
        guard let jsonURL = bundle.url(forResource: "tsukiiro-chainon.mms-expected", withExtension: "json"),
              let binURL = bundle.url(forResource: "tsukiiro-chainon.mms-emission", withExtension: "f32") else {
            throw XCTSkip("MMS emission fixture not in the test bundle.")
        }
        let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: jsonURL))
        let data = try Data(contentsOf: binURL)
        let classes = expected.labels.count
        XCTAssertEqual(classes, 29)
        XCTAssertEqual(data.count, expected.frames * classes * 4)
        var logProbs = [Float](repeating: 0, count: expected.frames * classes)
        _ = logProbs.withUnsafeMutableBytes { data.copyBytes(to: $0) }

        // Pin frames outside the sung regions (±0.5 s) to blank, as the aligner does.
        var sung = [Bool](repeating: false, count: expected.frames)
        for r in expected.regions {
            let f0 = max(0, Int((r[0] - 0.5) / expected.frameSec))
            let f1 = min(expected.frames, Int((r[1] + 0.5) / expected.frameSec))
            for f in f0..<f1 { sung[f] = true }
        }
        for f in 0..<expected.frames where sung[f] == false {
            for c in 0..<classes { logProbs[f * classes + c] = -1e4 }
            logProbs[f * classes] = 0
        }

        var tokens: [Int] = []
        var wordRanges: [Range<Int>] = []
        for word in expected.words {
            let start = tokens.count
            for ch in word {
                let idx = expected.labels.firstIndex(of: String(ch))
                XCTAssertNotNil(idx, "unmapped char \(ch)")
                tokens.append(idx!)
            }
            wordRanges.append(start..<tokens.count)
        }

        let spans = try XCTUnwrap(CTCViterbi.align(logProbs: logProbs, frames: expected.frames, classes: classes, tokens: tokens))
        XCTAssertEqual(spans.count, tokens.count)
        var startDiffs: [Int] = []
        for (i, range) in wordRanges.enumerated() {
            startDiffs.append(abs(spans[range.lowerBound].start - expected.wordStartFrames[i]))
            XCTAssertEqual(spans[range.upperBound - 1].end, expected.wordEndFrames[i], "word \(i) end")
        }
        XCTAssertEqual(startDiffs.max() ?? 0, 0, "word start frames differ from torchaudio: \(startDiffs)")
    }
}
