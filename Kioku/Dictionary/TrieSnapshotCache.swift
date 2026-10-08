import Foundation

// Where the app keeps its saved trie (DictionaryTrie+Snapshot) between launches: one file in
// Caches, tagged with the dictionary file it was built from. Caches because it is rebuilt from the
// dictionary whenever it is missing or stale, so iOS may purge it freely.
nonisolated enum TrieSnapshotCache {
    // The snapshot file.
    static var fileURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("dictionary-trie.snapshot")
    }

    // The trie saved for the dictionary at `databaseURL`, or nil when there is none for that exact
    // file (first launch, a new dictionary, a purged cache).
    static func load(forDatabaseAt databaseURL: URL) -> DictionaryTrie? {
        guard let key = DictionaryTrie.snapshotKey(forDatabaseAt: databaseURL),
              FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL, options: .alwaysMapped)
            return DictionaryTrie.restored(from: data, dictionaryKey: key)
        } catch {
            AppLog.error(.dictionary, "Trie snapshot unreadable: \(error)")
            return nil
        }
    }

    // Saves `trie`, built from the dictionary at `databaseURL`, for the next launch. Replaces any
    // older snapshot; a failure only costs the next launch a rebuild.
    static func save(_ trie: DictionaryTrie, forDatabaseAt databaseURL: URL) {
        guard let key = DictionaryTrie.snapshotKey(forDatabaseAt: databaseURL) else { return }
        do {
            try trie.snapshotData(dictionaryKey: key).write(to: fileURL, options: .atomic)
        } catch {
            AppLog.error(.dictionary, "Trie snapshot not saved: \(error)")
        }
    }
}
