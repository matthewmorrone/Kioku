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

    // Records a per-entry lookup, moving it to the front. Dedupes by canonical_entry_id.
    func record(canonicalEntryID: Int64, surface: String) {
        entries.removeAll { $0.kind == .entry && $0.canonicalEntryID == canonicalEntryID }
        entries.insert(
            HistoryEntry(canonicalEntryID: canonicalEntryID, surface: surface, lookedUpAt: Date(), kind: .entry),
            at: 0
        )
        trimAndPersist()
    }

    // Records a free-text search phrase the user submitted from the search field.
    // Dedupes by query text — re-submitting the same phrase moves it to the front rather
    // than creating a duplicate row. Empty / whitespace-only queries are dropped so we
    // don't pollute history when the user focuses the field and dismisses.
    func record(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        entries.removeAll { $0.kind == .query && $0.surface == trimmed }
        entries.insert(
            HistoryEntry(canonicalEntryID: 0, surface: trimmed, lookedUpAt: Date(), kind: .query),
            at: 0
        )
        trimAndPersist()
    }

    // Re-points a per-entry history row to a different dictionary entry, keeping its position
    // and timestamp. Because .entry rows dedupe by id ("e:<id>"), the target id must be unique:
    // any pre-existing row for the target entry is folded into the re-pointed slot.
    func repoint(historyID: String, toEntryID newID: Int64, surface: String) {
        guard let old = entries.first(where: { $0.id == historyID && $0.kind == .entry }),
              old.canonicalEntryID != newID else { return }

        let repointed = HistoryEntry(canonicalEntryID: newID, surface: surface, lookedUpAt: old.lookedUpAt, kind: .entry)
        var placed = false
        var updated: [HistoryEntry] = []
        for entry in entries {
            // Replace the source row in place, and drop any other row already holding the target id.
            if entry.id == historyID || (entry.kind == .entry && entry.canonicalEntryID == newID) {
                if !placed {
                    updated.append(repointed)
                    placed = true
                }
            } else {
                updated.append(entry)
            }
        }
        entries = updated
        persist()
    }

    // Removes one entry. Accepts the composite Identifiable ID ("e:<id>" or "q:<text>"),
    // not the canonical entry id, so query rows can be removed without ID collision.
    func remove(historyID: String) {
        entries.removeAll { $0.id == historyID }
        persist()
    }

    // Removes one entry by canonical entry ID. .entry rows only — query rows ignored.
    func remove(id: Int64) {
        entries.removeAll { $0.kind == .entry && $0.canonicalEntryID == id }
        persist()
    }

    // Caps the entries list and writes once.
    private func trimAndPersist() {
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        persist()
    }

    // Removes many entries in one persist cycle. Multi-select delete in WordsView must use this
    // instead of looping over remove(id:) so the JSON encode + UserDefaults write happens once
    // instead of N times — the per-item loop is what freezes the UI on bulk history clears.
    func remove(ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { $0.kind == .entry && ids.contains($0.canonicalEntryID) }
        persist()
    }

    // Bulk-delete by composite history IDs ("e:<id>" / "q:<text>"). Same single-persist
    // discipline as remove(ids:) — needed when multi-select picks up query rows.
    func remove(historyIDs: Set<String>) {
        guard !historyIDs.isEmpty else { return }
        entries.removeAll { historyIDs.contains($0.id) }
        persist()
    }

    // Bulk-delete `.entry` rows by canonical entry id. Lets the unified Int64 word-selection
    // remove History rows without first round-tripping through composite "e:<id>" strings.
    func remove(canonicalEntryIDs: Set<Int64>) {
        guard !canonicalEntryIDs.isEmpty else { return }
        entries.removeAll { $0.kind == .entry && canonicalEntryIDs.contains($0.canonicalEntryID) }
        persist()
    }

    // Removes all history entries.
    func clear() {
        entries = []
        persist()
    }

    // Replaces the history store with one bounded, most-recent-first snapshot.
    // Dedupes by composite id so .query and .entry rows can coexist without collision.
    func replaceAll(with entries: [HistoryEntry]) {
        var dedupedByID: [String: HistoryEntry] = [:]
        for entry in entries.sorted(by: { $0.lookedUpAt > $1.lookedUpAt }) {
            if dedupedByID[entry.id] == nil {
                dedupedByID[entry.id] = entry
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
