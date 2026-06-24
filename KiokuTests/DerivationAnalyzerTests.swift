import XCTest
@testable import Kioku

// Verifies the rule-based derivation detection that drives the word-detail header line.
// The analyzer is pure: each test injects a stub resolver mapping lemma → JMdict POS tags,
// so no dictionary database is needed.
final class DerivationAnalyzerTests: XCTestCase {

    private func resolver(_ map: [String: [String]]) -> DerivationAnalyzer.BaseResolver {
        { map[$0] ?? [] }
    }

    // MARK: Nominalizers さ / み

    func testIAdjectiveNominalizerSa() {
        let result = DerivationAnalyzer.analyze(
            surface: "弱さ", components: ["弱", "さ"], baseResolver: resolver(["弱い": ["adj-i"]]))
        XCTAssertEqual(result?.summary, "Derived noun — from い-adjective 弱い + nominalizing suffix さ")
    }

    func testIAdjectiveNominalizerMi() {
        let result = DerivationAnalyzer.analyze(
            surface: "弱み", components: [], baseResolver: resolver(["弱い": ["adj-i"]]))
        XCTAssertEqual(result?.summary, "Derived noun — from い-adjective 弱い + nominalizing suffix み")
    }

    func testNaAdjectiveNominalizer() {
        // 静かさ: stem+い (静かい) doesn't resolve; the bare stem 静か resolves as a na-adjective.
        let result = DerivationAnalyzer.analyze(
            surface: "静かさ", components: [], baseResolver: resolver(["静か": ["adj-na"]]))
        XCTAssertEqual(result?.summary, "Derived noun — from な-adjective 静か + nominalizing suffix さ")
    }

    func testNominalizerSkippedWhenStemNotAdjective() {
        // みさ (a name) ends in さ but the stem み isn't an adjective → not a derivation.
        XCTAssertNil(DerivationAnalyzer.analyze(
            surface: "みさ", components: [], baseResolver: resolver([:])))
    }

    // MARK: Honorific prefix

    func testHonorificPrefix() {
        let result = DerivationAnalyzer.analyze(
            surface: "お酒", components: [], baseResolver: resolver(["酒": ["n"]]))
        XCTAssertEqual(result?.summary, "Honorific form — prefix お + noun 酒")
    }

    func testHonorificPrefixRequiresKanjiStem() {
        // おとこ written in kana must not misfire even though とこ (床) resolves as a noun.
        XCTAssertNil(DerivationAnalyzer.analyze(
            surface: "おとこ", components: [], baseResolver: resolver(["とこ": ["n"]])))
    }

    // MARK: Suffixes

    func testCollectivePlural() {
        let result = DerivationAnalyzer.analyze(
            surface: "子供たち", components: [], baseResolver: resolver(["子供": ["n"]]))
        XCTAssertEqual(result?.summary, "Collective noun — 子供 + pluralizing suffix たち")
    }

    func testPluralizingRaFiresOnPronounBase() {
        // 彼ら: 彼 is a pronoun, so the pluralizing ら applies.
        let result = DerivationAnalyzer.analyze(
            surface: "彼ら", components: [], baseResolver: resolver(["彼": ["pn"]]))
        XCTAssertEqual(result?.summary, "Collective noun — 彼 + pluralizing suffix ら")
    }

    func testPluralizingRaSkippedOnNominalBase() {
        // きよら (清ら): the trailing ら is the archaic 形容動詞-forming suffix, not the pluralizer,
        // and きよ resolves only as a noun. A nominal base must NOT trigger the plural rule.
        XCTAssertNil(DerivationAnalyzer.analyze(
            surface: "きよら", components: [], baseResolver: resolver(["きよ": ["n"]])))
    }

    func testAdjectivalTeki() {
        let result = DerivationAnalyzer.analyze(
            surface: "科学的", components: [], baseResolver: resolver(["科学": ["n"]]))
        XCTAssertEqual(result?.summary, "Adjectival noun — 科学 + suffix 的 (“-ic / -ical”)")
    }

    func testSuruNounKa() {
        let result = DerivationAnalyzer.analyze(
            surface: "自動化", components: [], baseResolver: resolver(["自動": ["n"]]))
        XCTAssertEqual(result?.summary, "Suru-noun — 自動 + suffix 化 (“-ization”)")
    }

    func testPoliteAddress() {
        let result = DerivationAnalyzer.analyze(
            surface: "王様", components: [], baseResolver: resolver(["王": ["n"]]))
        XCTAssertEqual(result?.summary, "Polite address — 王 + honorific suffix 様")
    }

    // MARK: Compound verbs

    func testCompoundVerb() {
        let result = DerivationAnalyzer.analyze(
            surface: "食べ始める", components: ["食べる", "始める"],
            baseResolver: resolver(["食べる": ["v1"], "始める": ["v1"]]))
        XCTAssertEqual(result?.summary, "Compound verb — 食べる + auxiliary 始める (begin to ~)")
    }

    func testCompoundVerbSkippedWhenBaseNotVerb() {
        // Last component is an auxiliary surface but the lead part isn't verbal → not a compound verb.
        XCTAssertNil(DerivationAnalyzer.analyze(
            surface: "なんとかある", components: ["なんとか", "ある"],
            baseResolver: resolver(["なんとか": ["exp"]])))
    }

    // MARK: て-form auxiliary compounds

    func testTeFormAuxiliaryYuku() {
        // 生きてゆく is a lexicalized expression entry (one segment), so detection is on the string.
        let result = DerivationAnalyzer.analyze(
            surface: "生きてゆく", components: ["生きてゆく"], baseResolver: resolver([:]))
        XCTAssertEqual(result?.summary, "Compound verb — 生きて + auxiliary ゆく (go on ~ing)")
    }

    func testTeFormAuxiliaryWithVoicedLinker() {
        // 読んでくる: the で linker (after a voiced sound) is accepted just like て.
        let result = DerivationAnalyzer.analyze(
            surface: "読んでくる", components: [], baseResolver: resolver([:]))
        XCTAssertEqual(result?.summary, "Compound verb — 読んで + auxiliary くる (come to ~ / gradually ~)")
    }

    func testAuxiliaryVerbWithoutTeLinkerSkipped() {
        // A word ending in くる without a て/で linker is not a te-form compound.
        XCTAssertNil(DerivationAnalyzer.analyze(
            surface: "さくる", components: [], baseResolver: resolver([:])))
    }

    // MARK: Lexicalized passive verbs

    func testLexicalizedPassive() {
        // 生まれる ← 生む: strip れる, 生ま → 生む, confirm 生む is a verb.
        let result = DerivationAnalyzer.analyze(
            surface: "生まれる", components: [], baseResolver: resolver(["生む": ["v5m", "vt"]]))
        XCTAssertEqual(result?.summary, "Passive verb — derived from 生む (生む + passive ～れる)")
    }

    func testPassiveSkippedWhenReconstructedBaseNotVerb() {
        // 疲れる: 疲か isn't a verb, so the lexicalized-passive rule must not fire.
        XCTAssertNil(DerivationAnalyzer.analyze(
            surface: "疲れる", components: [], baseResolver: resolver([:])))
    }

    // MARK: Non-derivations

    func testPlainNounReturnsNil() {
        XCTAssertNil(DerivationAnalyzer.analyze(
            surface: "朝", components: [], baseResolver: resolver(["朝": ["n"]])))
    }
}
