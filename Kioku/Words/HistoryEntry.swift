import Foundation

// One recall-able event in the Words-tab History list.
//
// Two kinds:
// - .entry — a per-dict-entry lookup, keyed by canonical_entry_id. The user tapped a specific
//   dictionary headword and we record it so they can recall the entry later. Each entry id
//   appears at most once; re-lookup moves it to the front.
// - .query — a free-text search phrase the user submitted (Enter / Done on the keyboard).
//   canonicalEntryID is 0 since no specific entry is implied; surface holds the full query text.
//   Each distinct query string appears at most once; re-submitting moves it to the front.
nonisolated struct HistoryEntry: Codable, Identifiable {
    nonisolated enum Kind: String, Codable {
        case entry
        case query
    }

    let canonicalEntryID: Int64
    let surface: String
    let lookedUpAt: Date
    let kind: Kind

    // Composite identifier so .entry rows dedupe by entry id and .query rows dedupe by
    // their text. Without this, every .query row would collide on canonicalEntryID=0.
    var id: String {
        switch kind {
        case .entry: return "e:\(canonicalEntryID)"
        case .query: return "q:\(surface)"
        }
    }

    init(canonicalEntryID: Int64, surface: String, lookedUpAt: Date, kind: Kind = .entry) {
        self.canonicalEntryID = canonicalEntryID
        self.surface = surface
        self.lookedUpAt = lookedUpAt
        self.kind = kind
    }

    // V1 history entries (pre-kind discriminator) decode as .entry. Without the explicit
    // init, JSONDecoder throws on the missing `kind` key and the whole persisted history
    // list silently empties on first launch after upgrade.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canonicalEntryID = try container.decode(Int64.self, forKey: .canonicalEntryID)
        surface = try container.decode(String.self, forKey: .surface)
        lookedUpAt = try container.decode(Date.self, forKey: .lookedUpAt)
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .entry
    }
}
