import XCTest
@testable import Kioku

@MainActor
final class VerbConjugatorTests: XCTestCase {

    // MARK: Ichidan

    func test_ichidan_plain() {
        let groups = VerbConjugator.conjugationGroups(for: "食べる", verbClass: .ichidan)
        let plain = groups.first(where: { $0.name == "Plain" })!
        XCTAssertEqual(plain.rows[0].surface, "食べる")
        XCTAssertEqual(plain.rows[1].surface, "食べない")
        XCTAssertEqual(plain.rows[2].surface, "食べた")
        XCTAssertEqual(plain.rows[3].surface, "食べなかった")
    }

    func test_ichidan_polite() {
        let groups = VerbConjugator.conjugationGroups(for: "食べる", verbClass: .ichidan)
        let polite = groups.first(where: { $0.name == "Polite" })!
        XCTAssertEqual(polite.rows[0].surface, "食べます")
        XCTAssertEqual(polite.rows[1].surface, "食べません")
        XCTAssertEqual(polite.rows[2].surface, "食べました")
        XCTAssertEqual(polite.rows[3].surface, "食べませんでした")
    }

    func test_ichidan_teForm() {
        let groups = VerbConjugator.conjugationGroups(for: "食べる", verbClass: .ichidan)
        let te = groups.first(where: { $0.name == "Te-form" })!
        XCTAssertEqual(te.rows[0].surface, "食べて")
        XCTAssertEqual(te.rows[1].surface, "食べたり")
    }

    func test_ichidan_naideSezu() {
        let groups = VerbConjugator.conjugationGroups(for: "食べる", verbClass: .ichidan)
        let g = groups.first(where: { $0.name == "Without doing" })!
        XCTAssertEqual(g.rows[0].surface, "食べないで")
        XCTAssertEqual(g.rows[1].surface, "食べずに")
        XCTAssertEqual(g.rows[2].surface, "食べぬ／ん")
    }

    func test_ichidan_nounForm() {
        let groups = VerbConjugator.conjugationGroups(for: "食べる", verbClass: .ichidan)
        let g = groups.first(where: { $0.name == "Noun form" })!
        XCTAssertEqual(g.rows[0].surface, "食べ")
    }

    // MARK: Godan

    func test_godan_su_plain() {
        let groups = VerbConjugator.conjugationGroups(for: "探す", verbClass: .godan)
        let plain = groups.first(where: { $0.name == "Plain" })!
        XCTAssertEqual(plain.rows[0].surface, "探す")
        XCTAssertEqual(plain.rows[1].surface, "探さない")
        XCTAssertEqual(plain.rows[2].surface, "探した")
        XCTAssertEqual(plain.rows[3].surface, "探さなかった")
    }

    func test_godan_ku_teForm() {
        let groups = VerbConjugator.conjugationGroups(for: "書く", verbClass: .godan)
        let te = groups.first(where: { $0.name == "Te-form" })!
        XCTAssertEqual(te.rows[0].surface, "書いて")
    }

    func test_godan_iku_teForm() {
        // 行く is irregular — て-form is いって not いいて
        let groups = VerbConjugator.conjugationGroups(for: "行く", verbClass: .godan)
        let te = groups.first(where: { $0.name == "Te-form" })!
        XCTAssertEqual(te.rows[0].surface, "行って")
    }

    func test_godan_naideSezu() {
        let groups = VerbConjugator.conjugationGroups(for: "探す", verbClass: .godan)
        let g = groups.first(where: { $0.name == "Without doing" })!
        XCTAssertEqual(g.rows[0].surface, "探さないで")
        XCTAssertEqual(g.rows[1].surface, "探さずに")
        XCTAssertEqual(g.rows[2].surface, "探さぬ／ん")
    }

    // MARK: Suru

    func test_suru_plain() {
        let groups = VerbConjugator.conjugationGroups(for: "勉強する", verbClass: .suru)
        let plain = groups.first(where: { $0.name == "Plain" })!
        XCTAssertEqual(plain.rows[0].surface, "勉強する")
        XCTAssertEqual(plain.rows[1].surface, "勉強しない")
        XCTAssertEqual(plain.rows[2].surface, "勉強した")
        XCTAssertEqual(plain.rows[3].surface, "勉強しなかった")
    }

    func test_suru_naideSezu() {
        let groups = VerbConjugator.conjugationGroups(for: "勉強する", verbClass: .suru)
        let g = groups.first(where: { $0.name == "Without doing" })!
        XCTAssertEqual(g.rows[0].surface, "勉強しないで")
        XCTAssertEqual(g.rows[1].surface, "勉強せずに")
        XCTAssertEqual(g.rows[2].surface, "勉強せぬ／ん")
    }

    // MARK: Kuru

    func test_kuru_plain() {
        let groups = VerbConjugator.conjugationGroups(for: "来る", verbClass: .kuru)
        let plain = groups.first(where: { $0.name == "Plain" })!
        XCTAssertEqual(plain.rows[0].surface, "来る")
        XCTAssertEqual(plain.rows[1].surface, "来ない")
        XCTAssertEqual(plain.rows[2].surface, "来た")
        XCTAssertEqual(plain.rows[3].surface, "来なかった")
    }

    // MARK: Detect verb class

    func test_detectVerbClass_ichidan() {
        XCTAssertEqual(VerbConjugator.detectVerbClass(fromJMDictPosTags: ["v1"]), .ichidan)
    }

    func test_detectVerbClass_godan() {
        XCTAssertEqual(VerbConjugator.detectVerbClass(fromJMDictPosTags: ["v5s"]), .godan)
    }

    func test_detectVerbClass_suru() {
        XCTAssertEqual(VerbConjugator.detectVerbClass(fromJMDictPosTags: ["vs-i"]), .suru)
    }

    func test_detectVerbClass_kuru() {
        XCTAssertEqual(VerbConjugator.detectVerbClass(fromJMDictPosTags: ["vk"]), .kuru)
    }

    // MARK: Irregulars

    func test_kureru_imperative() {
        // くれる's imperative is the bare stem くれ, not the regular ichidan くれろ
        let groups = VerbConjugator.conjugationGroups(for: "くれる", verbClass: .ichidan)
        let imperative = groups.first(where: { $0.name == "Imperative" })!
        XCTAssertEqual(imperative.rows[0].surface, "くれ")
    }

    func test_zuru_usesJiStem() {
        // -ずる verbs (vz) conjugate like their -じる twin everywhere except the dictionary form
        let groups = VerbConjugator.conjugationGroups(for: "論ずる", verbClass: .ichidan)
        let plain = groups.first(where: { $0.name == "Plain" })!
        XCTAssertEqual(plain.rows[0].surface, "論ずる")
        XCTAssertEqual(plain.rows[1].surface, "論じない")
        XCTAssertEqual(plain.rows[2].surface, "論じた")
        let te = groups.first(where: { $0.name == "Te-form" })!
        XCTAssertEqual(te.rows[0].surface, "論じて")
    }

    func test_aru_suppletiveNegative() {
        // ある has no negative conjugation of its own — plain negative is ない, not あらない
        let groups = VerbConjugator.conjugationGroups(for: "ある", verbClass: .godan)
        let plain = groups.first(where: { $0.name == "Plain" })!
        XCTAssertEqual(plain.rows[1].surface, "ない")
        XCTAssertEqual(plain.rows[3].surface, "なかった")
        let conditional = groups.first(where: { $0.name == "Conditional" })!
        XCTAssertEqual(conditional.rows[1].surface, "なければ")
        // Past and polite forms stay regular
        XCTAssertEqual(plain.rows[2].surface, "あった")
        let polite = groups.first(where: { $0.name == "Polite" })!
        XCTAssertEqual(polite.rows[1].surface, "ありません")
    }

    func test_honorificGodanAru_kudasaru() {
        // くださる takes an い-stem for ます/imperative, not the regular り/れ columns
        let groups = VerbConjugator.conjugationGroups(for: "くださる", verbClass: .godan)
        let polite = groups.first(where: { $0.name == "Polite" })!
        XCTAssertEqual(polite.rows[0].surface, "くださいます")
        let imperative = groups.first(where: { $0.name == "Imperative" })!
        XCTAssertEqual(imperative.rows[0].surface, "ください")
        // Negative and te-form stay regular
        let plain = groups.first(where: { $0.name == "Plain" })!
        XCTAssertEqual(plain.rows[1].surface, "くださらない")
        let te = groups.first(where: { $0.name == "Te-form" })!
        XCTAssertEqual(te.rows[0].surface, "くださって")
    }

    func test_honorificGodanAru_irassharu() {
        let groups = VerbConjugator.conjugationGroups(for: "いらっしゃる", verbClass: .godan)
        let polite = groups.first(where: { $0.name == "Polite" })!
        XCTAssertEqual(polite.rows[0].surface, "いらっしゃいます")
        let imperative = groups.first(where: { $0.name == "Imperative" })!
        XCTAssertEqual(imperative.rows[0].surface, "いらっしゃい")
    }

    func test_godan_yuku_teForm() {
        // ゆく/逝く share 行く's irregularity even though they don't end in the kanji 行
        let groups = VerbConjugator.conjugationGroups(for: "逝く", verbClass: .godan)
        let te = groups.first(where: { $0.name == "Te-form" })!
        XCTAssertEqual(te.rows[0].surface, "逝って")
    }

    func test_godan_tou_teForm() {
        // 問う keeps the pre-onbin うて／うた instead of って／った
        let groups = VerbConjugator.conjugationGroups(for: "問う", verbClass: .godan)
        let te = groups.first(where: { $0.name == "Te-form" })!
        XCTAssertEqual(te.rows[0].surface, "問うて")
        let plain = groups.first(where: { $0.name == "Plain" })!
        XCTAssertEqual(plain.rows[2].surface, "問うた")
    }

    func test_detectVerbClass_kureruSpecialClass() {
        XCTAssertEqual(VerbConjugator.detectVerbClass(fromJMDictPosTags: ["v1-s"]), .ichidan)
    }

    func test_detectVerbClass_zuru() {
        XCTAssertEqual(VerbConjugator.detectVerbClass(fromJMDictPosTags: ["vz"]), .ichidan)
    }

    func test_detectVerbClass_godanAru() {
        XCTAssertEqual(VerbConjugator.detectVerbClass(fromJMDictPosTags: ["v5aru"]), .godan)
    }

    // MARK: Key forms

    func test_keyForms_ichidan() {
        let forms = VerbConjugator.keyForms(for: "食べる", verbClass: .ichidan)
        XCTAssertEqual(forms.count, 3)
        XCTAssertEqual(forms[0].label, "Te-form")
        XCTAssertEqual(forms[0].surface, "食べて")
        XCTAssertEqual(forms[1].label, "Negative")
        XCTAssertEqual(forms[1].surface, "食べない")
        XCTAssertEqual(forms[2].label, "Past")
        XCTAssertEqual(forms[2].surface, "食べた")
    }
}
