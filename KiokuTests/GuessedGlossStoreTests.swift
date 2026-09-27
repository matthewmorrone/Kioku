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
        GuessedGlossStore(defaults: defaults).setGloss("light (French 'lumière')", for: "リュミエール")
        XCTAssertEqual(GuessedGlossStore(defaults: defaults).gloss(for: "リュミエール"), "light (French 'lumière')")
    }

    // Blank guesses are not stored, so a failed reply can be retried later.
    func testBlankGlossIsNotStored() {
        let store = GuessedGlossStore(defaults: defaults)
        store.setGloss("   ", for: "シェノン")
        XCTAssertNil(store.gloss(for: "シェノン"))
    }

    // A stored guess is returned before any breakdown or model is consulted.
    func testGuessPrefersStoredGloss() async {
        let store = GuessedGlossStore(defaults: defaults)
        store.setGloss("stored", for: "シェノン")
        let breakdown = [SongWord(surface: "シェノン", sungRomaji: "shenon", definition: "from breakdown")]
        let guess = await GlossGuesser.guess(surface: "シェノン", lineContext: "涙色のシェノン", breakdownWords: breakdown, store: store)
        XCTAssertEqual(guess, "stored")
    }

    // With nothing stored, the song breakdown's gloss for the same surface is used.
    func testGuessUsesBreakdownGloss() async {
        let store = GuessedGlossStore(defaults: defaults)
        let breakdown = [SongWord(surface: "シェノン", sungRomaji: "shenon", definition: "link (French chaînon)")]
        let guess = await GlossGuesser.guess(surface: "シェノン", lineContext: "涙色のシェノン", breakdownWords: breakdown, store: store)
        XCTAssertEqual(guess, "link (French chaînon)")
    }

    // Replies are cut to their first line, unquoted, and rejected when too long to be a gloss.
    func testCleanedReply() {
        XCTAssertEqual(GlossGuesser.cleaned("\"light (French 'lumière')\"\nextra"), "light (French 'lumière')")
        XCTAssertNil(GlossGuesser.cleaned("   \n"))
        XCTAssertNil(GlossGuesser.cleaned(String(repeating: "a", count: 200)))
    }
}
