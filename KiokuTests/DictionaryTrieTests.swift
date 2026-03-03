import XCTest
import Kioku

final class DictionaryTrieTests: XCTestCase {

    // MARK: - Setup

    // Fetches dictionary surfaces from DictionaryStore for trie construction.
    private func fetchSurfaces() throws -> [String] {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let databaseURL = repositoryRoot.appendingPathComponent("Resources").appendingPathComponent("dictionary.sqlite")

        let store = try DictionaryStore(databaseURL: databaseURL)
        return try store.fetchAllSurfaces()
    }

    private func makeTrie() throws -> DictionaryTrie {
        return DictionaryTrie(surfaces: try fetchSurfaces())
    }

    // MARK: - Load Tests

    // Verifies loading the real database populates a large non-empty trie.
    func testLoadBuildsNonZeroSurfaceCount() throws {
        let trie = try makeTrie()

        XCTAssertTrue(trie.surfaceCount > 400000, "Expected trie to load more than 400000 surfaces.")
    }

    // Verifies repeated load calls do not rebuild or change surface totals.
    func testLoadIsIdempotent() throws {
        let surfaces = try fetchSurfaces()
        let trie = DictionaryTrie(surfaces: surfaces)
        let initialCount = trie.surfaceCount

        trie.build(from: surfaces)

        XCTAssertEqual(trie.surfaceCount, initialCount, "Second load should not change surfaceCount.")
    }

    // MARK: - Contains Tests

    // Verifies trie contains a known kana surface from JMdict.
    func testContainsKnownKanaSurface() throws {
        let trie = try makeTrie()
        XCTAssertTrue(trie.contains("する"), "Expected trie to contain known kana surface 'する'.")
    }

    // Verifies trie contains a known kanji surface from JMdict.
    func testContainsKnownKanjiSurface() throws {
        let trie = try makeTrie()
        XCTAssertTrue(trie.contains("光る"), "Expected trie to contain known kanji surface '光る'.")
    }

    // Verifies trie rejects unknown surfaces.
    func testContainsRejectsUnknownSurface() throws {
        let trie = try makeTrie()
        XCTAssertFalse(trie.contains("🛸🛸🛸"), "Expected unknown surface to be absent from trie.")
    }

    // Verifies insertion normalization allows lookup across decomposed/composed forms.
    func testContainsRespectsNormalization() throws {
        let trie = try makeTrie()
        let decomposed = "カフェ\u{3099}" // カフェ゙
        let composed = decomposed.precomposedStringWithCanonicalMapping

        trie.insert(decomposed)

        XCTAssertTrue(trie.contains(decomposed), "Expected trie to contain inserted decomposed surface.")
        XCTAssertTrue(trie.contains(composed), "Expected trie normalization to match composed equivalent surface.")
    }

    // MARK: - Prefix Tests

    // Verifies known leading prefixes are discoverable.
    func testHasPrefixTrueForValidPrefix() throws {
        let trie = try makeTrie()
        XCTAssertTrue(trie.hasPrefix("す"), "Expected prefix 'す' to exist in trie.")
    }

    // Verifies invalid prefixes are rejected.
    func testHasPrefixFalseForInvalidPrefix() throws {
        let trie = try makeTrie()
        XCTAssertFalse(trie.hasPrefix("🛸"), "Expected prefix '🛸' to be absent from trie.")
    }

    // MARK: - Idempotency Tests

    // Verifies inserting the same surface repeatedly only counts one terminal surface.
    func testInsertIsIdempotentForSurfaceCount() {
        let trie = DictionaryTrie()
        trie.insert("する")
        let firstCount = trie.surfaceCount

        trie.insert("する")

        XCTAssertEqual(trie.surfaceCount, firstCount, "Repeated insertion should not increase surfaceCount.")
    }

    // Verifies trie loading finishes within a practical startup bound.
    func testTrieBuildUnderTwoSeconds() throws {
        let surfaces = try fetchSurfaces()
        let startTime = Date()
        _ = DictionaryTrie(surfaces: surfaces)
        let elapsed = Date().timeIntervalSince(startTime)

        XCTAssertLessThan(elapsed, 2.0, "Expected trie build under 2 seconds, got \(elapsed) seconds.")
    }
}
