import XCTest
@testable import Kioku

// Characterizes LearnedWordStore: saving, the one-entry-per-spelling rule, editing, removal,
// backup replacement, and persistence across instances. Each case gets its own UserDefaults
// suite so cases never touch .standard or each other.
@MainActor
final class LearnedWordStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    // Fresh, isolated defaults per case.
    override func setUp() async throws {
        try await super.setUp()
        suiteName = "kioku-learnedWords-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    // Drops the per-case suite.
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // A store over this case's suite.
    private func makeStore() -> LearnedWordStore {
        LearnedWordStore(defaults: defaults, storageKey: "kioku.learnedWords.test")
    }

    // A saved spelling is listed, trimmed, and found by its spelling.
    func testSaveAddsTrimmedSpelling() {
        let store = makeStore()
        store.save(spelling: " ウエファース ", kind: .spellingOf(entSeq: 1_074_520))

        XCTAssertEqual(store.words.map(\.spelling), ["ウエファース"])
        XCTAssertEqual(store.word(forSpelling: "ウエファース")?.kind, .spellingOf(entSeq: 1_074_520))
    }

    // Saving a spelling again replaces its meaning instead of adding a second entry.
    func testSavingSameSpellingReplacesKind() {
        let store = makeStore()
        store.save(spelling: "ミンツ", kind: .spellingOf(entSeq: 1))
        store.save(spelling: "ミンツ", kind: .newWord(reading: "みんつ", meaning: "mints"))

        XCTAssertEqual(store.words.count, 1)
        XCTAssertEqual(store.words.first?.kind, .newWord(reading: "みんつ", meaning: "mints"))
    }

    // A blank spelling is ignored.
    func testBlankSpellingIsIgnored() {
        let store = makeStore()
        store.save(spelling: "  ", kind: .spellingOf(entSeq: 1))

        XCTAssertTrue(store.words.isEmpty)
    }

    // update edits in place, remove forgets.
    func testUpdateAndRemove() throws {
        let store = makeStore()
        store.save(spelling: "馳け寄る", kind: .spellingOf(entSeq: 1_244_750))
        var word = try XCTUnwrap(store.words.first)
        word.spelling = "馳け寄せる"
        store.update(word)
        XCTAssertEqual(store.words.map(\.spelling), ["馳け寄せる"])

        store.remove(id: word.id)
        XCTAssertTrue(store.words.isEmpty)
    }

    // The set survives a new store instance (it's what the next launch reads).
    func testPersistsAcrossInstances() {
        makeStore().save(spelling: "カステイラ", kind: .newWord(reading: "かすていら", meaning: "castella"))

        XCTAssertEqual(makeStore().words.map(\.spelling), ["カステイラ"])
    }

    // A backup import replaces the whole set.
    func testReplaceAll() {
        let store = makeStore()
        store.save(spelling: "ミンツ", kind: .spellingOf(entSeq: 1))
        let restored = LearnedWord(id: UUID(), spelling: "ドロップス", kind: .newWord(reading: "どろっぷす", meaning: "drops"), createdAt: Date(timeIntervalSince1970: 0))
        store.replaceAll(with: [restored])

        XCTAssertEqual(store.words, [restored])
        XCTAssertEqual(makeStore().words, [restored])
    }
}
