import Combine
import Foundation

// Persists a bounded recency list of looked-up words keyed by canonical_entry_id.
// Each entry appears at most once; re-lookup moves it to the front.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []

    private let storageKey = "kioku.history.v1"
    private let maxEntries = 200

    init() {
        entries = []
        StartupTimer.measure("HistoryStore.init") {
            load()
        }
    }

    // Records a lookup event, moving the entry to the front (most recent first).
    // Removes any prior record for the same canonical_entry_id before inserting.
    func record(canonicalEntryID: Int64, surface: String) {
        entries.removeAll { $0.canonicalEntryID == canonicalEntryID }
        entries.insert(
            HistoryEntry(canonicalEntryID: canonicalEntryID, surface: surface, lookedUpAt: Date()),
            at: 0
        )
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        persist()
    }

    // Removes one entry by canonical entry ID.
    func remove(id: Int64) {
        entries.removeAll { $0.canonicalEntryID == id }
        persist()
    }

    // Removes all history entries.
    func clear() {
        entries = []
        persist()
    }

    // Replaces the history store with one bounded, most-recent-first snapshot.
    func replaceAll(with entries: [HistoryEntry]) {
        var dedupedByID: [Int64: HistoryEntry] = [:]
        for entry in entries.sorted(by: { $0.lookedUpAt > $1.lookedUpAt }) {
            if dedupedByID[entry.canonicalEntryID] == nil {
                dedupedByID[entry.canonicalEntryID] = entry
            }
        }

        let ordered = dedupedByID.values.sorted(by: { $0.lookedUpAt > $1.lookedUpAt })
        self.entries = Array(ordered.prefix(maxEntries))
        persist()
    }

    // Decodes persisted history entries from UserDefaults on first access.
    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }
        entries = decoded
    }

    // Encodes the current entries array and writes it to UserDefaults.
    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
