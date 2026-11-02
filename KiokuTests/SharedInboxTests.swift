import XCTest
@testable import Kioku

// Covers the share-extension hand-off: items round-trip through the inbox folder oldest first and
// are removed once read, bad files are reported, and shared text/links become notes.
@MainActor
final class SharedInboxTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kioku-inbox-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // Items come back oldest first and the inbox is empty afterwards.
    func testDrainReturnsItemsOldestFirstAndEmptiesInbox() throws {
        let older = SharedInboxItem(title: "a", text: "one", createdAt: Date(timeIntervalSince1970: 1))
        let newer = SharedInboxItem(title: "b", url: "https://example.com", createdAt: Date(timeIntervalSince1970: 2))
        try SharedInbox.enqueue(newer, in: directory)
        try SharedInbox.enqueue(older, in: directory)

        let result = SharedInbox.drain(from: directory)
        XCTAssertEqual(result.items, [older, newer])
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertTrue(SharedInbox.drain(from: directory).items.isEmpty)
    }

    // An unreadable file is reported and removed, and the good ones still arrive.
    func testCorruptFileIsReportedAndDropped() throws {
        let good = SharedInboxItem(text: "keep")
        try SharedInbox.enqueue(good, in: directory)
        try Data("nope".utf8).write(to: directory.appendingPathComponent("bad.json"))

        let result = SharedInbox.drain(from: directory)
        XCTAssertEqual(result.items, [good])
        XCTAssertEqual(result.problems.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("bad.json").path))
    }

    // Shared text is kept as written and titled by the typed title, else its first line.
    func testTextBecomesNoteWithTitle() async {
        let typed = await SharedInboxImporter.note(for: SharedInboxItem(title: "Mine", text: "今日は\n晴れ")) { _ in "" }
        XCTAssertEqual(typed?.title, "Mine")
        XCTAssertEqual(typed?.content, "今日は\n晴れ")
        let untitled = await SharedInboxImporter.note(for: SharedInboxItem(text: "今日は\n晴れ")) { _ in "" }
        XCTAssertEqual(untitled?.title, "今日は")
    }

    // A link becomes the fetched text; if the fetch fails the link itself is kept.
    func testLinkFetchesTextAndFallsBackToTheLink() async {
        struct Failure: Error {}
        let fetched = await SharedInboxImporter.note(for: SharedInboxItem(url: "https://example.com/a")) { _ in "ページ" }
        XCTAssertEqual(fetched?.content, "ページ")
        XCTAssertEqual(fetched?.title, "example.com")
        let kept = await SharedInboxImporter.note(for: SharedInboxItem(url: "https://example.com/a")) { _ in throw Failure() }
        XCTAssertEqual(kept?.content, "https://example.com/a")
    }
}
