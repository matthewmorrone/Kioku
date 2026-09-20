import XCTest
@testable import Kioku

// Guards segmentation QUALITY, which the rest of the suite does not: the lattice and deinflection
// tests pass whether the chosen path is 80% or 89% right, and stayed green while the app's
// segmenter was wired to the wrong frequency map.
//
// Gold tokens come from Tatoeba's Japanese indices (the Tanaka Corpus "B lines"): sentences
// tokenized into JMdict headwords by the JMdict maintainers — the same granularity this segmenter
// aims for. The 300 fixture sentences are held out: nothing in SegmenterScoring was fitted on them.
// Re-measure or refit with ~/Projects/kioku-segmentation-eval.
@MainActor
final class SegmentationQualityTests: XCTestCase {

    // One fixture sentence: its text and the character spans of its gold tokens.
    private struct GoldSentence: Decodable {
        let text: String
        let tokens: [[Int]]
    }

    // Loads the held-out gold fixture checked in beside this file.
    private func loadGoldSentences() throws -> [GoldSentence] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/segmentation/held-out-gold.jsonl")
        let decoder = JSONDecoder()
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { try decoder.decode(GoldSentence.self, from: Data($0.utf8)) }
    }

    // Segments `text` with the shipped default strategy and returns each segment's character span.
    private func segmentSpans(of text: String, using segmenter: Segmenter) -> [(start: Int, end: Int)] {
        var spans: [(start: Int, end: Int)] = []
        var offset = 0
        for edge in segmenter.longestMatchEdges(for: text) {
            spans.append((start: offset, end: offset + edge.surface.count))
            offset += edge.surface.count
        }
        return spans
    }

    // Returns the chosen surfaces for `text` under the shipped default strategy.
    private func segments(of text: String) throws -> [String] {
        UserDefaults.standard.removeObject(forKey: SegmenterSettings.strategyKey)
        UserDefaults.standard.removeObject(forKey: SegmenterSettings.splitsParticleClustersKey)
        return try TestReadResources.shared().segmenter.longestMatchEdges(for: text).map(\.surface)
    }

    // The quality floor. Each gold token is either reproduced exactly, cut through by one of our
    // segments (a segment that overlaps it partially — the real error, e.g. はだ|きしめたい), or
    // merged/split at a coarser or finer granularity. The floors sit well below what the shipped
    // model scores on this fixture (exact 91.6%, cut-through 0.43%) and well above what the two
    // regressions seen in practice score: the segmenter fed per-entry propagated ranks (85.0% /
    // 1.62%) and the greedy strategy with its demotion list (82.4% / 3.41%).
    func testHeldOutQualityFloor() throws {
        UserDefaults.standard.removeObject(forKey: SegmenterSettings.strategyKey)
        // Measured with particle clusters left whole: the gold tokens keep には and ですか as units, and
        // this floor is about which path wins, not how finely a chosen cluster is displayed.
        UserDefaults.standard.set(false, forKey: SegmenterSettings.splitsParticleClustersKey)
        defer { UserDefaults.standard.removeObject(forKey: SegmenterSettings.splitsParticleClustersKey) }
        let segmenter = try TestReadResources.shared().segmenter
        var goldCount = 0
        var exactCount = 0
        var cutThroughCount = 0

        for sentence in try loadGoldSentences() {
            let spans = segmentSpans(of: sentence.text, using: segmenter)
            for token in sentence.tokens {
                let (start, end) = (token[0], token[1])
                goldCount += 1
                let overlapping = spans.filter { $0.start < end && $0.end > start }
                if overlapping.count == 1, overlapping[0].start == start, overlapping[0].end == end {
                    exactCount += 1
                } else if overlapping.contains(where: { span in
                    (span.start < start || span.end > end) && !(span.start <= start && span.end >= end)
                }) {
                    cutThroughCount += 1
                }
            }
        }

        let exactRate = Double(exactCount) / Double(goldCount)
        let cutThroughRate = Double(cutThroughCount) / Double(goldCount)
        XCTAssertGreaterThanOrEqual(exactRate, 0.90, "exact-match rate fell to \(exactRate) over \(goldCount) gold tokens")
        XCTAssertLessThanOrEqual(cutThroughRate, 0.008, "cut-through rate rose to \(cutThroughRate) over \(goldCount) gold tokens")
    }

    // だけ + どきっと are both real words; だけど + きっと wins only when だけ, だけど and きっと carry
    // the ranks of those spellings as written. Found on device when the app was mis-wired.
    func testDakedoKitto() throws {
        XCTAssertEqual(try segments(of: "だけどきっと"), ["だけど", "きっと"])
    }

    // つ始める resolves as a conjugated form of a common verb; the inflection-step cost is what
    // stops it pulling はい off the front of はいつ.
    func testDoesNotFuseHaiBeforeItsu() throws {
        XCTAssertEqual(try segments(of: "問題はいつ始めるか"), ["問題", "は", "いつ", "始める", "か"])
    }

    // The same two kana, opposite answers: はい is "yes" here…
    func testKeepsHaiAsYes() throws {
        XCTAssertEqual(try segments(of: "はい、そうです"), ["はい", "、", "そうです"])
    }

    // …and は + いつも here. A per-surface denylist can only get one of the pair right.
    func testSplitsHaBeforeItsumo() throws {
        XCTAssertEqual(try segments(of: "はいつも笑っている"), ["は", "いつも", "笑っている"])
    }

    // があ is a dictionary entry (onomatopoeia); taking it strands ります.
    func testDoesNotFuseGaA() throws {
        XCTAssertEqual(try segments(of: "視力障害があります"), ["視力障害", "が", "あります"])
    }

    // がそ is the reading of 画素, which nobody writes in kana.
    func testDoesNotFuseGaSo() throws {
        XCTAssertEqual(try segments(of: "私たちがそこへ行く"), ["私たち", "が", "そこ", "へ", "行く"])
    }

    // はだ is the reading of 肌; in kana it is far rarer than は + a following verb.
    func testDoesNotFuseHaDa() throws {
        XCTAssertEqual(try segments(of: "ほんとうはだきしめたい"), ["ほんとう", "は", "だきしめたい"])
    }

    // The transition table is loaded by the constructor the app and the tests share. If it fails to
    // load, segmentation silently falls back to word costs alone and every test below still runs.
    func testTransitionTableIsLoaded() throws {
        XCTAssertNotNil(try TestReadResources.shared().segmenter.transitionTable)
    }

    // 結婚 + 式を挙げました are both dictionary units and cheaper by word cost alone; what follows a
    // noun (を) and what follows を (a verb) is what the transition costs add.
    func testKeepsCompoundBeforeObjectParticle() throws {
        XCTAssertEqual(try segments(of: "結婚式を挙げました"), ["結婚式", "を", "挙げました"])
    }

    // なかったら is ない in the たら-conditional. Without an い-adjective たら rule it resolved only to a
    // non-word, and がな + かったら won.
    func testConditionalOfNai() throws {
        XCTAssertEqual(try segments(of: "嵐がなかったら"), ["嵐", "が", "なかったら"])
    }

    // Negative past of an ichidan verb is one conjugated form, not 食べられ + なかった.
    func testIchidanNegativePastIsOneSegment() throws {
        XCTAssertEqual(try segments(of: "食べられなかった"), ["食べられなかった"])
    }

    // The たり form belongs to its verb; り must not be pulled onto する.
    func testTariFormStaysWithItsVerb() throws {
        XCTAssertEqual(try segments(of: "減ったりする"), ["減ったり", "する"])
    }
    // Particle clusters are shown as their parts by default…
    func testSplitsParticleClustersByDefault() throws {
        XCTAssertEqual(try segments(of: "そこには誰もいない"), ["そこ", "に", "は", "誰も", "いない"])
        XCTAssertEqual(try segments(of: "そうですか"), ["そう", "です", "か"])
    }

    // …but an entry that merely looks like particles keeps its own meaning: なのに is "even though".
    func testKeepsLexicalizedParticleWordsWhole() throws {
        XCTAssertEqual(try segments(of: "雨なのに"), ["雨", "なのに"])
        XCTAssertEqual(try segments(of: "でも行く"), ["でも", "行く"])
    }

    // With the option off the path search's own units come through.
    func testParticleClustersStayWholeWhenOptionIsOff() throws {
        UserDefaults.standard.set(false, forKey: SegmenterSettings.splitsParticleClustersKey)
        defer { UserDefaults.standard.removeObject(forKey: SegmenterSettings.splitsParticleClustersKey) }
        let segmenter = try TestReadResources.shared().segmenter
        XCTAssertEqual(segmenter.longestMatchEdges(for: "そこには誰もいない").map(\.surface), ["そこ", "には", "誰も", "いない"])
    }

    // Conjugations that stack one class-changing ending on another — polite over progressive, past
    // over passive, negative over progressive — are one verb form each. They resolve only when a
    // rule's rulesIn names the class of the INFLECTED form (ている conjugates as ichidan, ない as an
    // い-adjective); typed by the lemma's class, none of these had a lattice edge at all.
    func testStackedConjugationsAreOneSegment() throws {
        XCTAssertEqual(try segments(of: "知っています"), ["知っています"])
        XCTAssertEqual(try segments(of: "彼に言われた"), ["彼", "に", "言われた"])
        XCTAssertEqual(try segments(of: "まだ持っていない"), ["まだ", "持っていない"])
    }

    // Godan polite negative and volitional, and なさい on a godan stem.
    func testGodanPoliteNegativeVolitionalAndNasai() throws {
        XCTAssertEqual(try segments(of: "お金がありません"), ["お金", "が", "ありません"])
        XCTAssertEqual(try segments(of: "本を読もう"), ["本", "を", "読もう"])
        XCTAssertEqual(try segments(of: "早くおきなさい"), ["早く", "おきなさい"])
    }

    // 行く is the one godan く-verb whose past is った, not いた; 行った must reach 行く, not only 行う.
    func testIttaResolvesToIku() throws {
        let lemmas = try TestReadResources.shared().segmenter.resolvedTrieLemmas(for: "行った")
        XCTAssertTrue(lemmas.contains("行く"), "行った resolved to \(lemmas.sorted())")
    }
}
