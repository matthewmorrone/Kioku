import Foundation
@testable import Kioku

// Reuses one real dictionary-backed segmenter pipeline across unit tests to avoid repeated trie allocation.
final class TestReadResources {
    private static var cachedResources: TestReadResources?

    let dictionaryStore: DictionaryStore
    let trie: DictionaryTrie
    let deinflector: Deinflector
    let segmenter: Segmenter

    // Returns a process-wide shared test harness so full dictionary loading happens only once.
    static func shared() throws -> TestReadResources {
        if let cachedResources {
            return cachedResources
        }

        let resources = try TestReadResources()
        cachedResources = resources
        return resources
    }

    // Builds the real dictionary-backed segmenter pipeline used by integration tests.
    private init() throws {
        let dictionaryStore = try DictionaryStore(databaseURL: Self.dictionaryDatabaseURL())
        let trie = DictionaryTrie()

        for surface in try dictionaryStore.fetchAllSurfaces() {
            trie.insert(surface)
        }

        let deinflector = try Deinflector(jsonFileURL: Self.deinflectionRulesURL(), trie: trie)

        self.dictionaryStore = dictionaryStore
        self.trie = trie
        self.deinflector = deinflector
        self.segmenter = Segmenter(trie: trie, deinflector: deinflector)
    }

    // Resolves the repository root from the checked-in test file location.
    private static func repositoryRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // Resolves the checked-in SQLite dictionary path used by the real app pipeline.
    private static func dictionaryDatabaseURL() -> URL {
        repositoryRootURL()
            .appendingPathComponent("Resources")
            .appendingPathComponent("dictionary.sqlite")
    }

    // Resolves the checked-in deinflection rules file used by the real app pipeline.
    private static func deinflectionRulesURL() -> URL {
        repositoryRootURL()
            .appendingPathComponent("Resources")
            .appendingPathComponent("deinflection.json")
    }
}