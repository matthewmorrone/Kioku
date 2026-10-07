import XCTest
@testable import Kioku

// Pins SingHistoryStore's persistence, per-note ordering and cap, against an isolated
// UserDefaults suite so real history is never touched.
@MainActor
final class SingHistoryStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    // Gives each test its own empty defaults suite.
    override func setUp() {
        super.setUp()
        suiteName = "kioku-sing-history-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    // Removes the suite so no state leaks between runs.
    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // Builds a session for `note` at `secondsAgo` with the given counts.
    private func record(_ note: UUID, secondsAgo: Double, heard: Int = 1, graded: Int = 2) -> SingSessionRecord {
        SingSessionRecord(noteID: note, date: Date(timeIntervalSinceNow: -secondsAgo), scope: "Song",
                          strictness: .normal, heardCount: heard, gradedCount: graded, missedSurfaces: ["夢"])
    }

    // A recorded session survives into a fresh store and comes back for its note only.
    func testSessionPersistsPerNote() {
        let note = UUID(), other = UUID()
        SingHistoryStore(defaults: defaults).append(record(note, secondsAgo: 10))
        let reloaded = SingHistoryStore(defaults: defaults)
        XCTAssertEqual(reloaded.sessions(for: note).count, 1)
        XCTAssertEqual(reloaded.sessions(for: note).first?.missedSurfaces, ["夢"])
        XCTAssertTrue(reloaded.sessions(for: other).isEmpty)
    }

    // Sessions come back newest first.
    func testSessionsAreNewestFirst() {
        let note = UUID()
        let store = SingHistoryStore(defaults: defaults)
        store.append(record(note, secondsAgo: 100, heard: 1))
        store.append(record(note, secondsAgo: 5, heard: 2))
        XCTAssertEqual(store.sessions(for: note).map(\.heardCount), [2, 1])
    }

    // A session with nothing graded isn't kept.
    func testEmptySessionIsNotStored() {
        let note = UUID()
        let store = SingHistoryStore(defaults: defaults)
        store.append(record(note, secondsAgo: 1, heard: 0, graded: 0))
        XCTAssertTrue(store.sessions(for: note).isEmpty)
    }

    // Each note keeps at most the cap, dropping its oldest.
    func testHistoryIsCappedPerNote() {
        let note = UUID()
        let store = SingHistoryStore(defaults: defaults)
        for i in 0..<(SingHistoryStore.maximumPerNote + 3) { store.append(record(note, secondsAgo: Double(1000 - i))) }
        let sessions = store.sessions(for: note)
        XCTAssertEqual(sessions.count, SingHistoryStore.maximumPerNote)
        XCTAssertTrue(sessions.allSatisfy { $0.date > Date(timeIntervalSinceNow: -998) })
    }
}
