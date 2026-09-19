import XCTest
@testable import Kioku

// Runs old-form (kyujitai) text through the real dictionary-backed segmenter. The contract: text
// written with old-form kanji segments exactly like the same text in modern spelling, while every
// edge keeps the characters as they were written.
@MainActor
final class KyujitaiSegmentationTests: XCTestCase {

    // Returns the chosen segmentation of a string as UTF-16 ranges paired with each edge's surface.
    private func segmentation(of text: String) throws -> [(range: NSRange, surface: String)] {
        let segmenter = try TestReadResources.shared().segmenter
        return segmenter.longestMatchEdges(for: text).map { (NSRange($0.start..<$0.end, in: text), $0.surface) }
    }

    // Returns just the chosen surfaces, for readable failure messages.
    private func surfaces(of text: String) throws -> [String] {
        try segmentation(of: text).map(\.surface)
    }

    // Sentence pairs that differ only in kanji orthography, each exercising a different old-form character mix.
    private let oldAndModernPairs: [(old: String, modern: String)] = [
        ("痛みが殘るよ", "痛みが残るよ"),
        ("ぼくはやっと氣づいたのさ", "ぼくはやっと気づいたのさ"),
        ("電氣をつけて學校へ行く", "電気をつけて学校へ行く"),
        ("國の體制を變える", "国の体制を変える"),
        ("彼は病氣で寢ていた", "彼は病気で寝ていた"),
    ]

    // Verifies old-form text is split at exactly the same boundaries as its modern spelling.
    func testOldFormTextSegmentsLikeItsModernSpelling() throws {
        for (old, modern) in oldAndModernPairs {
            let oldSegmentation = try segmentation(of: old)
            let modernSegmentation = try segmentation(of: modern)
            XCTAssertEqual(
                oldSegmentation.map(\.range), modernSegmentation.map(\.range),
                "\(old) segmented as \(oldSegmentation.map(\.surface)) but \(modern) as \(modernSegmentation.map(\.surface))"
            )
        }
    }

    // Verifies every edge keeps the original spelling: normalization is a matching aid, never a rewrite of the text.
    func testEdgeSurfacesKeepTheOriginalSpelling() throws {
        for (old, _) in oldAndModernPairs {
            XCTAssertEqual(try surfaces(of: old).joined(), old)
        }
    }

    // Regression for the reported note: 殘る and 氣づいた must be single words, not a kanji stranded from its okurigana.
    func testReportedWordsStayWhole() throws {
        let remain = try surfaces(of: "痛みが殘るよ")
        XCTAssertTrue(remain.contains("殘る"), "got \(remain)")
        XCTAssertFalse(remain.contains("殘"), "got \(remain)")

        let notice = try surfaces(of: "ぼくはやっと氣づいたのさ")
        XCTAssertTrue(notice.contains("氣づいた"), "got \(notice)")
        XCTAssertFalse(notice.contains("氣"), "got \(notice)")
    }

    // Regression: 賠 is not an old form of 陪, so 賠償 must still be found as a word.
    func testDistinctCharactersAreNotNormalizedIntoOtherWords() throws {
        XCTAssertTrue(try surfaces(of: "賠償を求める").contains("賠償"))
    }
}
