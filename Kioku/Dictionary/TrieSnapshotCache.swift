import CryptoKit
import Foundation

// Where the app keeps its saved trie (DictionaryTrie+Snapshot) between launches: one file in
// Caches, tagged with what the trie was built from. Caches because it is rebuilt from the
// dictionary whenever it is missing or stale, so iOS may purge it freely.
nonisolated enum TrieSnapshotCache {
    // The snapshot file.
    static var fileURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("dictionary-trie.snapshot")
    }

    // What the trie is built from: the installed dictionary release (its tag, and checksum on the
    // dev channel) and the Custom Words written into it (CustomWordApplier's signature in
    // custom_word_state). Not the file's modification time: applying Custom Words rewrites the file
    // on every launch. Nil when there is no installed marker.
    static func key(store: DictionaryStore) -> String? {
        guard let marker = DictionaryDownloadManager.installedMarker else { return nil }
        // The signature is the whole applied list as JSON, so it goes in as a digest.
        let digest = SHA256.hash(data: Data((store.customWordSignature() ?? "").utf8))
        return "\(marker)|\(digest.map { String(format: "%02x", $0) }.joined())"
    }

    // The trie saved under `key`, or nil when there is none for it (first launch, a new dictionary,
    // changed Custom Words, a purged cache).
    static func load(key: String) -> DictionaryTrie? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL, options: .alwaysMapped)
            return DictionaryTrie.restored(from: data, dictionaryKey: key)
        } catch {
            AppLog.error(.dictionary, "Trie snapshot unreadable: \(error)")
            return nil
        }
    }

    // Saves `trie` under `key` for the next launch, replacing any older snapshot; a failure only
    // costs the next launch a rebuild.
    static func save(_ trie: DictionaryTrie, key: String) {
        do {
            try trie.snapshotData(dictionaryKey: key).write(to: fileURL, options: .atomic)
        } catch {
            AppLog.error(.dictionary, "Trie snapshot not saved: \(error)")
        }
    }
}
