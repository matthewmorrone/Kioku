import XCTest
@testable import Kioku

// Manual harness: segments the Moonlight Densetsu lyrics with the app's real
// segmenter (longest-match + deinflection) and dumps, per line, the chosen
// surface tokens and their lemmas — the "stemmed result". Also emits a flat,
// de-duplicated lemma vocabulary used to bias transcription / drive word-level
// alignment. Prints between grep-able markers; always passes.
@MainActor
final class StemmedLyricsDumpTests: XCTestCase {

    // Exact contents of ムーンライト伝説.txt (blank verse separators dropped).
    private let lines: [String] = [
        "ごめんね素直じゃなくて",
        "夢の中なら言える",
        "思考回路はショート寸前",
        "今すぐ会いたいよ",
        "泣きたくなるようなムーンライト",
        "電話もできないミッドナイト",
        "だって純情どうしよう",
        "ハートは万華鏡",
        "月の光に導かれ",
        "何度も巡り会う",
        "星座の瞬き数え",
        "占う恋の行方",
        "同じ地球に生まれたの",
        "ミラクルロマンス",
        "もう一度ふたりでウィークエンド",
        "神様かなえてハッピーエンド",
        "現在過去未来も",
        "あなたに首ったけ",
        "出会った時のなつかしい",
        "まなざし忘れない",
        "幾千万の星から",
        "あなたを見つけられる",
        "偶然もチャンスに換える",
        "生き方が好きよ",
        "不思議な奇跡クロスして",
        "何度も巡り会う",
        "星座の瞬き数え",
        "占う恋の行方",
        "同じ地球に生まれたの",
        "ミラクルロマンス",
        "信じているの",
        "ミラクルロマンス",
    ]

    func testDumpStemmedLyrics() throws {
        let resources = try TestReadResources.shared()
        let segmenter = resources.segmenter

        var vocab: [String] = []
        var seen = Set<String>()

        print(">>>STEMMED_BEGIN")
        for (i, line) in lines.enumerated() {
            let edges = segmenter.longestMatchResult(for: line).selectedEdges
            let tokens = edges.map { edge -> String in
                let lemma = segmenter.preferredLemma(for: edge.surface) ?? edge.lemma
                for w in [edge.surface, lemma] where w.isEmpty == false && seen.insert(w).inserted {
                    vocab.append(w)
                }
                return lemma.isEmpty || lemma == edge.surface ? edge.surface : "\(edge.surface)→\(lemma)"
            }
            print(String(format: "%2d  %@", i + 1, tokens.joined(separator: " | ")))
        }
        print(">>>STEMMED_END")

        // Flat vocabulary (surfaces + lemmas) for prompt biasing / word alignment.
        print(">>>VOCAB_BEGIN")
        print(vocab.joined(separator: "\n"))
        print(">>>VOCAB_END")

        XCTAssertFalse(vocab.isEmpty)
    }
}
