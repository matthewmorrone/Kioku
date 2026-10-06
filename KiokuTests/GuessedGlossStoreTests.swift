import XCTest
@testable import Kioku

// Pins GuessedGlossStore's persistence and GlossGuesser's reply cleanup, against an isolated
// UserDefaults suite so real guesses are never touched.
@MainActor
final class GuessedGlossStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    // Gives each test its own empty defaults suite.
    override func setUp() {
        super.setUp()
        suiteName = "kioku-guessed-gloss-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    // Removes the suite so no state leaks between runs.
    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // A stored guess survives into a fresh store over the same defaults.
    func testStoredGlossPersists() {
        GuessedGlossStore(defaults: defaults).setGloss("light (French 'lumière')", for: "リュミエール", in: "その物語リュミエール")
        XCTAssertEqual(GuessedGlossStore(defaults: defaults).gloss(for: "リュミエール", in: "その物語リュミエール"), "light (French 'lumière')")
    }

    // A guess belongs to the line it was made from; the same spelling in another line asks again.
    func testGlossIsKeyedByLine() {
        let store = GuessedGlossStore(defaults: defaults)
        store.setGloss("light (French 'lumière')", for: "リュミエール", in: "その物語リュミエール")
        XCTAssertNil(store.gloss(for: "リュミエール", in: "別の行のリュミエール"))
    }

    // Blank guesses are not stored, so a failed reply can be retried later.
    func testBlankGlossIsNotStored() {
        let store = GuessedGlossStore(defaults: defaults)
        store.setGloss("   ", for: "シェノン", in: "涙色のシェノン")
        XCTAssertNil(store.gloss(for: "シェノン", in: "涙色のシェノン"))
    }

    // A stored guess is returned before any breakdown or model is consulted.
    func testGuessPrefersStoredGloss() async {
        let store = GuessedGlossStore(defaults: defaults)
        store.setGloss("stored", for: "シェノン", in: "涙色のシェノン")
        let breakdown = [SongWord(surface: "シェノン", sungRomaji: "shenon", definition: "from breakdown")]
        let guess = await GlossGuesser.guess(surface: "シェノン", lineContext: "涙色のシェノン", breakdownWords: breakdown, store: store)
        XCTAssertEqual(guess, "stored")
    }

    // The breakdown's explanation goes into the request as context, not straight onto the sheet.
    func testPromptCarriesBreakdownExplanation() {
        let prompt = GlossGuesser.prompt(
            surface: "リュミエール",
            lineContext: "その物語リュミエール",
            breakdownNote: "light (French lumière), often symbolizes clarity or revelation"
        )
        XCTAssertTrue(prompt.contains("often symbolizes clarity or revelation"))
        XCTAssertTrue(prompt.contains("at most 8 words"))
    }

    // Replies are cut to their first line, unquoted, and rejected when too long to be a gloss.
    func testCleanedReply() {
        XCTAssertEqual(GlossGuesser.cleaned("\"light (French 'lumière')\"\nextra"), "light (French 'lumière')")
        XCTAssertNil(GlossGuesser.cleaned("   \n"))
        XCTAssertNil(GlossGuesser.cleaned(String(repeating: "a", count: 200)))
    }

    // Composite meanings live in their own map, so they never answer for an unknown-word guess.
    func testCompositeStoreIsSeparate() {
        let guesses = GuessedGlossStore(defaults: defaults)
        let composites = GuessedGlossStore(defaults: defaults, storageKey: "kioku.lookup.compositeGlosses")
        composites.setGloss("seems likely to happen", for: "起こりそう", in: "起こる + そう")
        XCTAssertEqual(composites.gloss(for: "起こりそう", in: "起こる + そう"), "seems likely to happen")
        XCTAssertNil(guesses.gloss(for: "起こりそう", in: "起こる + そう"))
    }

    // A helper-word form names its parts; a plain inflection names its form instead.
    func testCompositePromptNamesPartsOrForm() {
        let helper = CompositeGlossGuesser.prompt(
            surface: "起こりそう", lemmaLine: "起こる + そう", formDescription: "auxiliary", baseGloss: "to occur"
        )
        XCTAssertTrue(helper.contains("「起こる」 + 「そう」"))
        XCTAssertFalse(helper.contains("auxiliary"))
        XCTAssertTrue(helper.contains("「起こる」 means: to occur"))
        let inflected = CompositeGlossGuesser.prompt(
            surface: "言いたくない", lemmaLine: "言う", formDescription: "desiderative · negative", baseGloss: nil
        )
        XCTAssertTrue(inflected.contains("the desiderative · negative form of 「言う」"))
    }
}
