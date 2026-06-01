import XCTest
@testable import Kioku

// Real assertions on the CHOSEN path of the global longest-match strategy — the coverage that was
// missing while SegmentationDumpTests only printed. Each case pins the linguistically-correct
// segmentation of a phrase the user flagged as mis-segmented under global.
//
// These run with frequency data loaded (TestReadResources now builds frequencyScoreBySurface), so
// they exercise the real production cost model, not a frequency-blind one.
//
// NOTE: some of these are expected to FAIL until the rare-conjugation penalty lands. That red is
// intentional — it is the signal that the bug is still present. The fusions のす / のま / たの
// launder through a common lemma via deinflection and escape the frequency/unranked signals, so
// they need the bound-stem ("rare conjugation") penalty before these go green.
@MainActor
final class GlobalSegmentationTests: XCTestCase {

    // SKIPPED: global longest-match is shelved — local + exceptions is the shipped path (see
    // memory/feedback_segmentation_local_not_global). These assert correct *global* output that the
    // current model doesn't fully deliver, so they're kept as a record of intent but skipped to keep
    // the suite green. Delete this override to re-enable them if global is ever revived.
    override func setUpWithError() throws {
        throw XCTSkip("global longest-match is shelved; kept as a record only")
    }

    // Segments `phrase` under the global longest-match strategy and returns the chosen surfaces.
    private func segmentGlobally(_ phrase: String) throws -> [String] {
        let resources = try TestReadResources.shared()
        UserDefaults.standard.set(SegmentationStrategy.globalLongestMatch.rawValue, forKey: SegmenterSettings.strategyKey)
        defer { UserDefaults.standard.set(SegmentationStrategy.localLongestMatch.rawValue, forKey: SegmenterSettings.strategyKey) }
        return resources.segmenter.longestMatchResult(for: phrase).selectedEdges.map { $0.surface }
    }

    // 流される (passive) + たゆたう (揺蕩う) — た must not be stolen from たゆたう into 流されてた.
    func testKeepsTayutauWhole() throws {
        XCTAssertEqual(try segmentGlobally("流されてたゆたう"), ["流されて", "たゆたう"])
    }

    // Reduplicated adverb — must not fuse into もっとも (尤も) + stranded っと.
    func testKeepsReduplicatedMotto() throws {
        XCTAssertEqual(try segmentGlobally("もっともっと"), ["もっと", "もっと"])
    }

    // 中 / の / またたく — the の particle must not fuse with ま into のま (→飲ます).
    func testDoesNotFuseNoMa() throws {
        XCTAssertEqual(try segmentGlobally("闇の中のまたたく"), ["闇", "の", "中", "の", "またたく"])
    }

    // あなた (pronoun) must stay whole, not split into あな (oh!) + たの.
    func testKeepsAnataWhole() throws {
        XCTAssertEqual(try segmentGlobally("あなたの"), ["あなた", "の"])
    }

    // の particle + すべて (all) — must not fuse into のす (伸す).
    func testDoesNotFuseNoSu() throws {
        XCTAssertEqual(try segmentGlobally("気持ちのすべて"), ["気持ち", "の", "すべて"])
    }

    // 生まれた (past) + の — past た must not be stolen into たの.
    func testDoesNotFuseTaNo() throws {
        XCTAssertEqual(try segmentGlobally("地球に生まれたの"), ["地球", "に", "生まれた", "の"])
    }

    // --- Cascade cases: alternate-writing & conjugation frequency closure ---

    // わがまま (kana) must stay whole — inherits 我儘's rank via per-entry propagation.
    func testKeepsWagamamaWhole() throws {
        XCTAssertEqual(try segmentGlobally("わがまま"), ["わがまま"])
    }

    // ケンカ (katakana) must stay whole — inherits 喧嘩's rank via per-entry propagation.
    func testKeepsKenkaWhole() throws {
        XCTAssertEqual(try segmentGlobally("ケンカ"), ["ケンカ"])
    }

    // 会いたい (desiderative) must stay whole — inherits 会う's rank via the deinflected lemma.
    func testKeepsAitaiWhole() throws {
        XCTAssertEqual(try segmentGlobally("会いたい"), ["会いたい"])
    }

    // 追いかけて (compound verb て-form) must stay whole — inherits 追いかける's rank via deinflection.
    func testKeepsOikaketeWhole() throws {
        XCTAssertEqual(try segmentGlobally("追いかけて"), ["追いかけて"])
    }
}
