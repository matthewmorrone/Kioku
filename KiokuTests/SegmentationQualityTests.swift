import XCTest
@testable import Kioku

// Guards segmentation QUALITY, which the rest of the suite does not: the lattice and deinflection
// tests pass whether the chosen path is 80% or 89% right, and stayed green while the app's
// segmenter was wired to the wrong frequency map.
//
// Gold tokens come from Tatoeba's Japanese indices (the Tanaka Corpus "B lines"): sentences
// tokenized into JMdict headwords by the JMdict maintainers — the same granularity this segmenter
// aims for. The 300 fixture sentences are held out: nothing in SegmenterScoring was fitted on them.
// Re-measure or refit with scripts/segmentation-eval (see its README).
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
        let segmenter = try TestReadResources.shared().segmenter
        segmenter.splitsClusters = false
        defer { segmenter.splitsClusters = true }
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
        XCTAssertEqual(try segments(of: "はいつも笑っている"), ["は", "いつも", "笑って", "いる"])
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
        let segmenter = try TestReadResources.shared().segmenter
        segmenter.splitsClusters = false
        defer { segmenter.splitsClusters = true }
        XCTAssertEqual(segmenter.longestMatchEdges(for: "そこには誰もいない").map(\.surface), ["そこ", "には", "誰も", "いない"])
    }

    // Conjugations that stack one class-changing ending on another — polite over progressive, past
    // over passive, negative over progressive — are one verb form each. They resolve only when a
    // rule's rulesIn names the class of the INFLECTED form (ている conjugates as ichidan, ない as an
    // い-adjective); typed by the lemma's class, none of these had a lattice edge at all.
    func testStackedConjugationsAreOneSegment() throws {
        XCTAssertEqual(try segments(of: "知っています"), ["知っています"])
        XCTAssertEqual(try segments(of: "彼に言われた"), ["彼", "に", "言われた"])
        XCTAssertEqual(try segments(of: "まだ持っていない"), ["まだ", "持って", "いない"])
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
    // An ichidan verb's bare stem is a segment of its own before a separate word — 食べ + に + 行く —
    // and an adjective stem carries すぎる / そう as one form.
    func testIchidanStemAndAdjectiveStemAuxiliaries() throws {
        XCTAssertEqual(try segments(of: "ラーメンを食べに行きます"), ["ラーメン", "を", "食べ", "に", "行きます"])
        XCTAssertEqual(try segments(of: "仕事が忙しすぎる"), ["仕事", "が", "忙し", "すぎる"])
        XCTAssertEqual(try segments(of: "歩きながら話す"), ["歩きながら", "話す"])
    }

    // 考え and 過ぎ are dictionary words AND ichidan stems. They must not borrow 考える / 過ぎる's
    // frequency through stem recovery, or 考え|事ができない and 過ぎ|て become the cheaper paths.
    func testDictionaryWordsDoNotBorrowTheirVerbsFrequency() throws {
        XCTAssertEqual(try segments(of: "考え事ができない"), ["考え事", "が", "できない"])
        XCTAssertEqual(try segments(of: "時間が過ぎて"), ["時間", "が", "過ぎて"])
        XCTAssertEqual(try segments(of: "していて"), ["して", "いて"])
    }
    // A word written across katakana and hiragana is one segment — the dictionary entry ウソつき, and
    // katakana-stem verbs through their lemma (サボった → サボる)…
    func testWordsWrittenAcrossKanaScripts() throws {
        XCTAssertEqual(try segments(of: "ウソつきな君"), ["ウソつき", "な", "君"])
        XCTAssertEqual(try segments(of: "授業をサボった"), ["授業", "を", "サボった"])
        XCTAssertEqual(try segments(of: "消しゴムを買った"), ["消しゴム", "を", "買った"])
    }

    // …while a span that merely runs across the script switch is still refused: ビロード+の must not
    // become どの, nor ケンカ+もした 醸す. Their lemmas are not written across any switch.
    func testStillRefusesFusionsAcrossKanaScripts() throws {
        XCTAssertEqual(try segments(of: "ビロードの闇"), ["ビロード", "の", "闇"])
        XCTAssertEqual(try segments(of: "ケンカもしたけど"), ["ケンカ", "も", "した", "けど"])
    }
    // して, した and せよ are dictionary words AND conjugated forms of する. Priced as する itself with no
    // inflection step, they made なら|して and 恋|せよ cheaper than ならして and 恋せよ; they now pay
    // the step when their lemma prices them, and are classed as that reading (a verb's て-form after
    // を, not the adverb 均して). Both lines came from reviewing real lyrics.
    func testConjugatedFormsThatAreAlsoWordsPayTheirStep() throws {
        XCTAssertEqual(try segments(of: "ベルをならして"), ["ベル", "を", "ならして"])
        XCTAssertEqual(try segments(of: "恋せよ乙女"), ["恋せよ", "乙女"])
        XCTAssertEqual(try segments(of: "勉強していた"), ["勉強", "して", "いた"])
    }

    // なる after an adjective's く-form is its own word ("become"), not part of the adjective — and
    // the く-form must not be swallowed by なくなる ("to disappear"): not 切|なくなったり, でき|なくなる.
    func testAdjectiveKuFormAndNaruAreSeparateWords() throws {
        XCTAssertEqual(try segments(of: "切なくなったり"), ["切なく", "なったり"])
        XCTAssertEqual(try segments(of: "制御ができなくなる。"), ["制御", "が", "できなく", "なる", "。"])
        XCTAssertEqual(try segments(of: "泣きたくなるようなムーンライト"), ["泣きたく", "なる", "ような", "ムーンライト"])
    }
    // A number is a token of its own, priced like a common word — not unknown text — so the counter
    // after it is read whole (２ + 時間, not ２時 + 間). ヶ月 keeps its ヶ even though ヶ can never start a
    // word on its own. A digit + counter that is a dictionary word still wins on its frequency.
    func testNumbersAndCounters() throws {
        XCTAssertEqual(try segments(of: "２時間かかった"), ["２", "時間", "かかった"])
        XCTAssertEqual(try segments(of: "５ヶ月前"), ["５", "ヶ月", "前"])
        XCTAssertEqual(try segments(of: "３年間住んだ"), ["３", "年間", "住んだ"])
        XCTAssertEqual(try segments(of: "１日中寝ていた"), ["１日中", "寝て", "いた"])
        XCTAssertEqual(try segments(of: "２人で行く"), ["２人", "で", "行く"])
    }

    // て-form + よ must split even when よ is immediately followed by a bare noun with no
    // punctuation between them, as lyric line breaks routinely are. つたえ is also a common noun
    // (message/legend) and てよ is its own dictionary particle-expression, so つたえ｜てよ is a real
    // competing parse — it used to undercut つたえて｜よ because a w:よ→noun transition, rare in the
    // prose-trained table, priced above the old clamp. Real line: あいたいとささやく（つたえてよ
    // スターライト）. See transitionClampNats in SegmenterScoring.swift.
    func testTeFormPlusYoSplitsBeforeABareNoun() throws {
        XCTAssertEqual(
            try segments(of: "あいたいとささやく（つたえてよスターライト）"),
            ["あいたい", "と", "ささやく", "（", "つたえて", "よ", "スターライト", "）"]
        )
        XCTAssertEqual(try segments(of: "伝えてよ星"), ["伝えて", "よ", "星"])
        XCTAssertEqual(try segments(of: "見てよ空"), ["見て", "よ", "空"])
    }

    // A lone kana with no transition class of its own is priced below its JPDB rank
    // (SegmenterScoring.loneKanaPenalty): ま|って beat 待って on a line of its own. Kana-written 間
    // must still stand alone, and full-width English must stay one word per run.
    func testLoneKanaDoesNotSplitATeForm() throws {
        XCTAssertEqual(try segments(of: "まって"), ["まって"])
        XCTAssertEqual(try segments(of: "まってよ"), ["まって", "よ"])
        XCTAssertEqual(try segments(of: "すこしのまおつきあいください"), ["すこし", "の", "ま", "おつきあい", "ください"])
        XCTAssertEqual(try segments(of: "ＬＯＶＥがほしい"), ["ＬＯＶＥ", "が", "ほしい"])
    }

    // The ichidan imperative よ deinflection rule (よ→る for a v1 stem) was tried and reverted
    // (commit 4851340): on kana-only text it let および／いよ resolve as imperatives of おる／いる,
    // breaking these three sentences. The rule stays out; these guard against it — or an
    // equivalent — being reintroduced without re-checking kana2k.
    func testDoesNotFalselyResolveOyoOrIyoAsAnImperative() throws {
        XCTAssertEqual(try segments(of: "およせください"), ["お", "よせ", "ください"])
        XCTAssertEqual(try segments(of: "およみになる"), ["お", "よみ", "に", "なる"])
        XCTAssertEqual(try segments(of: "がいようのみにしよう"), ["がいよう", "のみ", "に", "しよう"])
    }

    // An unknown katakana word whose first kana is also a one-character entry (リ is a prefix, シ a
    // noun) lost its whole-run lattice edge once single kana stopped being gated for the path
    // search, and came out as リ + ュミエール. See the katakana fallback in Segmenter.buildLattice.
    func testUnknownKatakanaRunStaysWholeAfterASingleKanaEntry() throws {
        XCTAssertEqual(try segments(of: "その物語リュミエール"), ["その", "物語", "リュミエール"])
        XCTAssertEqual(try segments(of: "涙色のシェノン"), ["涙", "色", "の", "シェノン"])
    }
}
