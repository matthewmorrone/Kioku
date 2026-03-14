import Foundation
@testable import Kioku

// Describes recoverable test-resource resolution failures without aborting the test process.
private enum TestReadResourcesError: Error, LocalizedError {
    case missingReadableResource(fileName: String, checkedPaths: [String])

    var errorDescription: String? {
        switch self {
        case .missingReadableResource(let fileName, let checkedPaths):
            return "Missing readable test resource '\(fileName)'. Checked: \(checkedPaths.joined(separator: "; "))"
        }
    }
}

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
    private static func dictionaryDatabaseURL() throws -> URL {
        try resolveResourceURL(fileName: "dictionary.sqlite")
    }

    // Resolves the checked-in deinflection rules file used by the real app pipeline.
    private static func deinflectionRulesURL() throws -> URL {
        try resolveResourceURL(fileName: "deinflection.json")
    }

    // Loads grouped deinflection rules using the same resource resolution path as the shared test harness.
    static func groupedDeinflectionRules() throws -> [String: [DeinflectionRule]] {
        let rulesData = try Data(contentsOf: resolveResourceURL(fileName: "deinflection.json"))
        return try JSONDecoder().decode([String: [DeinflectionRule]].self, from: rulesData)
    }

    // Resolves a test resource from repository checkout paths or built bundle resources.
    private static func resolveResourceURL(fileName: String) throws -> URL {
        let repositoryCandidate = repositoryRootURL()
            .appendingPathComponent("Resources")
            .appendingPathComponent(fileName)

        var candidates: [URL] = [repositoryCandidate]

        let bundleCandidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle(for: TestReadResources.self).resourceURL
        ]

        for bundleResourceURL in bundleCandidates {
            if let bundleResourceURL {
                candidates.append(bundleResourceURL.appendingPathComponent(fileName))
            }
        }

        for bundle in Bundle.allBundles {
            if let resourceURL = bundle.resourceURL {
                candidates.append(resourceURL.appendingPathComponent(fileName))
            }
        }

        for bundle in Bundle.allFrameworks {
            if let resourceURL = bundle.resourceURL {
                candidates.append(resourceURL.appendingPathComponent(fileName))
            }
        }

        let fileManager = FileManager.default
        for candidate in candidates {
            if fileManager.isReadableFile(atPath: candidate.path) {
                return candidate
            }
        }

        throw TestReadResourcesError.missingReadableResource(
            fileName: fileName,
            checkedPaths: candidates.map(\.path)
        )
    }
}