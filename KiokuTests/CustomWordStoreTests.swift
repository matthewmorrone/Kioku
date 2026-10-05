import XCTest
@testable import Kioku

// Characterizes CustomWordStore: saving (and the stable ent_seq a new word gets), deletion,
// defaults offered once, Restore Defaults, reset, import replacement, backup replacement, and
// persistence across instances. Each case gets its own UserDefaults suite.
@MainActor
final class CustomWordStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    // Fresh, isolated defaults per case.
    override func setUp() async throws {
        try await super.setUp()
        suiteName = "kioku-customWords-tests-\(UUID().uuidString)"
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
    private func makeStore() -> CustomWordStore {
        CustomWordStore(defaults: defaults, storageKey: "kioku.customWords.test")
    }

    // A new word of its own; `defaultKey` makes it a default as the applier reports one.
    private func word(_ kana: String, gloss: String = "gloss", defaultKey: String? = nil, entSeq: Int64? = nil) -> CustomWord {
        CustomWord(
            id: UUID(), entSeq: entSeq, sameAsEntSeq: nil, kanji: [], kana: [kana],
            senses: [CustomWordSense(partOfSpeech: ["n"], misc: [], glosses: [gloss])],
            defaultKey: defaultKey
        )
    }

    // A saved new word gets the stable ent_seq derived from its headword, kept through an edit.
    func testSaveAssignsStableEntSeq() throws {
        let store = makeStore()
        store.save(word("ミンツ"))
        let saved = try XCTUnwrap(store.words.first)
        XCTAssertEqual(saved.entSeq, CustomWordIdentity.entSeq(forHeadword: "ミンツ"))

        var edited = saved
        edited.kana = ["ミンツー"]
        store.save(edited)
        XCTAssertEqual(store.words.count, 1)
        XCTAssertEqual(store.words.first?.entSeq, saved.entSeq)
    }

    // Extra spellings of an existing entry carry no ent_seq of their own.
    func testSameAsWordGetsNoEntSeq() {
        let store = makeStore()
        store.save(CustomWord(id: UUID(), entSeq: nil, sameAsEntSeq: 1_244_750, kanji: ["馳け寄る"], kana: [], senses: [], defaultKey: nil))
        XCTAssertNil(store.words.first?.entSeq)
    }

    // A default is offered once: deleting it survives a later dictionary reporting it again.
    func testDeletedDefaultIsNotReAdded() throws {
        let store = makeStore()
        store.addDefaults([word("ラララ", defaultKey: "ラララ", entSeq: -136_212_510)])
        let id = try XCTUnwrap(store.words.first?.id)
        store.remove(id: id)
        store.addDefaults([word("ラララ", defaultKey: "ラララ", entSeq: -136_212_510)])
        XCTAssertTrue(store.words.isEmpty)
    }

    // Restore Defaults brings a deleted default back and resets an edited one.
    func testRestoreDefaults() throws {
        let store = makeStore()
        store.addDefaults([word("ラララ", gloss: "la la la", defaultKey: "ラララ"), word("ユア", gloss: "your", defaultKey: "ユア")])
        var edited = try XCTUnwrap(store.words.first { $0.defaultKey == "ユア" })
        edited.senses = [CustomWordSense(partOfSpeech: [], misc: [], glosses: ["changed"])]
        store.save(edited)
        store.remove(id: try XCTUnwrap(store.words.first { $0.defaultKey == "ラララ" }).id)

        store.restoreDefaults()
        XCTAssertEqual(Set(store.words.compactMap { $0.senses.first?.glosses.first }), ["la la la", "your"])
    }

    // Reset leaves exactly the defaults; the user's own words go.
    func testResetToDefaults() {
        let store = makeStore()
        store.addDefaults([word("ラララ", defaultKey: "ラララ")])
        store.save(word("ミンツ"))
        store.resetToDefaults()
        XCTAssertEqual(store.words.map(\.defaultKey), ["ラララ"])
    }

    // An import replaces the list and keeps the offered defaults, so ones it leaves out stay gone.
    func testReplaceWordsKeepsOfferedDefaults() {
        let store = makeStore()
        store.addDefaults([word("ラララ", defaultKey: "ラララ")])
        store.replaceWords(with: [word("ドロップス")])
        XCTAssertEqual(store.words.map { $0.kana.first }, ["ドロップス"])
        store.addDefaults([word("ラララ", defaultKey: "ラララ")])
        XCTAssertEqual(store.words.count, 1)
    }

    // The list and offered defaults survive a new store instance.
    func testPersistsAcrossInstances() {
        let store = makeStore()
        store.addDefaults([word("ラララ", defaultKey: "ラララ")])
        store.save(word("カステイラ"))

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.words.compactMap { $0.kana.first }, ["ラララ", "カステイラ"])
        XCTAssertEqual(Set(reloaded.offeredDefaults.keys), ["ラララ"])
    }

    // A backup restore replaces list and offered defaults together.
    func testReplaceAllFromBackup() {
        let store = makeStore()
        store.save(word("ミンツ"))
        let restored = CustomWordStoreState(words: [word("ドロップス")], offeredDefaults: ["ユア": word("ユア", defaultKey: "ユア")])
        store.replaceAll(with: restored)
        XCTAssertEqual(store.words.compactMap { $0.kana.first }, ["ドロップス"])
        XCTAssertEqual(Set(store.offeredDefaults.keys), ["ユア"])
    }
}
