import XCTest
@testable import Kioku

// Characterizes WordListsStore — user-created word-list CRUD that backs the Words tab's
// "lists" UI. Each test gets its own UserDefaults suite so cases never collide with .standard
// or with each other when run in parallel.
@MainActor
final class WordListsStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private static let storageKey = "kioku.wordlists.test"

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "kioku-wordlists-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults, "Failed to construct test UserDefaults suite")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeStore() -> WordListsStore {
        WordListsStore(userDefaults: defaults, storageKey: Self.storageKey)
    }

    // A fresh suite produces an empty store.
    func testInitFromEmptyStorageIsEmpty() {
        XCTAssertTrue(makeStore().lists.isEmpty)
    }

    // create(name:) appends and persists.
    func testCreateAppendsAndPersists() {
        let writer = makeStore()
        writer.create(name: "Verbs")
        writer.create(name: "Adjectives")
        XCTAssertEqual(writer.lists.map(\.name), ["Verbs", "Adjectives"])

        let reader = makeStore()
        XCTAssertEqual(reader.lists.map(\.name), ["Verbs", "Adjectives"])
    }

    // rename(id:name:) updates the name; the id is stable across rename.
    func testRenameUpdatesNameAndKeepsID() {
        let store = makeStore()
        store.create(name: "Old")
        let id = store.lists[0].id

        store.rename(id: id, name: "New")
        XCTAssertEqual(store.lists[0].id, id)
        XCTAssertEqual(store.lists[0].name, "New")
    }

    // rename on a missing id is a no-op — protects callers that hand in stale ids without
    // crashing the UI.
    func testRenameMissingIdIsNoOp() {
        let store = makeStore()
        store.create(name: "Real")
        store.rename(id: UUID(), name: "Phantom")
        XCTAssertEqual(store.lists.map(\.name), ["Real"])
    }

    // delete(id:) drops one entry; others survive.
    func testDeleteRemovesOneEntry() {
        let store = makeStore()
        store.create(name: "A")
        store.create(name: "B")
        store.create(name: "C")
        let target = store.lists[1]

        store.delete(id: target.id)
        XCTAssertEqual(store.lists.map(\.name), ["A", "C"])
    }

    // delete on a missing id is a no-op.
    func testDeleteMissingIdIsNoOp() {
        let store = makeStore()
        store.create(name: "A")
        store.delete(id: UUID())
        XCTAssertEqual(store.lists.map(\.name), ["A"])
    }

    // move(from:to:) reorders the lists; mirrors SwiftUI's onMove signature.
    func testMoveReordersLists() {
        let store = makeStore()
        store.create(name: "A")
        store.create(name: "B")
        store.create(name: "C")

        store.move(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(store.lists.map(\.name), ["B", "C", "A"])
    }

    // replaceAll dedupes by id — guards against backup-restore paths that hand in a list with
    // duplicate ids (e.g., hand-edited JSON or a buggy older backup).
    func testReplaceAllDedupesByID() {
        let store = makeStore()
        let shared = UUID()
        let unique = UUID()
        let now = Date()
        store.replaceAll(with: [
            WordList(id: shared, name: "first-with-shared-id", createdAt: now),
            WordList(id: unique, name: "unique", createdAt: now),
            WordList(id: shared, name: "second-with-shared-id", createdAt: now),
        ])

        XCTAssertEqual(store.lists.count, 2)
        XCTAssertEqual(store.lists.map(\.id), [shared, unique])
        XCTAssertEqual(store.lists[0].name, "first-with-shared-id",
                       "first-seen entry with the shared id wins (filter keeps insert order)")
    }

    // replaceAll(with: []) clears everything and persists the empty state.
    func testReplaceAllWithEmptyClearsStore() {
        let store = makeStore()
        store.create(name: "doomed")
        store.replaceAll(with: [])

        XCTAssertTrue(store.lists.isEmpty)
        XCTAssertTrue(makeStore().lists.isEmpty)
    }

    // Persistence: a fresh store loads the entries the previous instance wrote, in order.
    func testEntriesSurviveAcrossInstances() {
        let writer = makeStore()
        writer.create(name: "First")
        writer.create(name: "Second")

        let reader = makeStore()
        XCTAssertEqual(reader.lists.map(\.name), ["First", "Second"])
    }

    // Reorder survives across instances — the persisted JSON encodes the array order, so a
    // post-reorder reader sees the same order as the writer.
    func testReorderPersistsAcrossInstances() {
        let writer = makeStore()
        writer.create(name: "A")
        writer.create(name: "B")
        writer.create(name: "C")
        writer.move(from: IndexSet(integer: 0), to: 3)

        let reader = makeStore()
        XCTAssertEqual(reader.lists.map(\.name), ["B", "C", "A"])
    }
}
