import XCTest
@testable import Kioku

// Pins cases that previously failed and have since been fixed (open cases live
// under "Still-broken segmentation cases" in docs/todo.md; resolved ones are
// listed at the bottom of that doc). Each test asserts both that the full
// surface appears as a lattice edge and that preferredLemma resolves to the
// expected base form, catching regressions in either the segmentation greedy
// walk or the lemma scoring pipeline that landed those fixes.
//
// New entries land here as cases move from "Still-broken" to the
// "Resolved / pinned" section of docs/todo.md — keeping that doc short and
// routing the long-tail verification through the regular test suite.
@MainActor
final class SegmentationKnownGoodTests: XCTestCase {

    // Asserts the surface appears as a full-span edge in the lattice AND
    // preferredLemma matches the expected dictionary lemma. Many of the
    // historical failures were "splits where it shouldn't" — this combined
    // check catches both the wrong-split and wrong-lemma flavors in one go.
    private func assertFullSpan(
        surface: String,
        expectedLemma: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let resources = try TestReadResources.shared()
        let edges = resources.segmenter.buildLattice(for: surface)
        XCTAssertTrue(
            edges.contains { $0.surface == surface },
            "Lattice for \(surface) has no full-span edge; surfaces=\(edges.map(\.surface))",
            file: file, line: line
        )
        let lemma = resources.segmenter.preferredLemma(for: surface)
        XCTAssertEqual(
            lemma, expectedLemma,
            "preferredLemma(\(surface)) — expected \(expectedLemma), got \(lemma ?? "nil")",
            file: file, line: line
        )
    }

    // つないだ — past tense of つなぐ. Previously split as つな|いだ.
    func testTsunaida() throws {
        try assertFullSpan(surface: "つないだ", expectedLemma: "つなぐ")
    }

    // まけない — negative of まける. Previously split as まけ|ない.
    func testMakenai() throws {
        try assertFullSpan(surface: "まけない", expectedLemma: "まける")
    }

    // その度 — adverbial phrase, one entry. Previously split as その|度.
    func testSonoTabi() throws {
        try assertFullSpan(surface: "その度", expectedLemma: "その度")
    }

    // 抱かれ — passive of 抱く. Previously missing readings (separate issue);
    // segmentation now produces the full span and resolves to 抱く.
    func testIdakare() throws {
        try assertFullSpan(surface: "抱かれ", expectedLemma: "抱く")
    }

    // トキメク — katakana spelling of ときめく. Previously split as トキ|メク.
    func testTokimeku() throws {
        try assertFullSpan(surface: "トキメク", expectedLemma: "ときめく")
    }

    // 月色 — compound noun. Previously not recognized as one entry.
    func testTsukiiro() throws {
        try assertFullSpan(surface: "月色", expectedLemma: "月色")
    }

    // しょげちゃうんだ — colloquial contracted form of しょげる. Previously
    // unrecognized; deinflection now reaches the base lemma.
    func testShogechaunda() throws {
        try assertFullSpan(surface: "しょげちゃうんだ", expectedLemma: "しょげる")
    }

    // プレイヤーズ — katakana loanword. Was missing from the lexicon; added to
    // extras.json so it now resolves.
    func testPlayers() throws {
        try assertFullSpan(surface: "プレイヤーズ", expectedLemma: "プレイヤーズ")
    }

    // ティアーズ — katakana loanword. Was missing from the lexicon; added to
    // extras.json so it now resolves.
    func testTears() throws {
        try assertFullSpan(surface: "ティアーズ", expectedLemma: "ティアーズ")
    }
}
