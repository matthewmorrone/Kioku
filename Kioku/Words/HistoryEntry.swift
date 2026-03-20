import Foundation

// One word lookup event — keyed by canonical_entry_id so each word appears at most once in the recency list.
struct HistoryEntry: Codable, Identifiable {
    let canonicalEntryID: Int64
    let surface: String
    let lookedUpAt: Date

    var id: Int64 { canonicalEntryID }
}
