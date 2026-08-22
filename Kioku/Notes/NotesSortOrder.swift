import Foundation

// How the Notes tab orders its list. `manual` is the default and preserves the user's
// drag-to-reorder arrangement (the order NotesStore persists in `_index.json`); every other
// case is a derived ordering applied for display only, so switching back to `manual` restores
// the stored arrangement untouched.
enum NotesSortOrder: String, CaseIterable, Identifiable {
    case manual
    case titleAToZ
    case titleZToA
    case recentlyModified
    case leastRecentlyModified
    case newestCreated
    case oldestCreated
    case longest
    case shortest
    case hardest
    case easiest
    case mostWordsLeft
    case fewestWordsLeft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "Manual Order"
        case .titleAToZ: "Title A to Z"
        case .titleZToA: "Title Z to A"
        case .recentlyModified: "Recently Modified"
        case .leastRecentlyModified: "Least Recently Modified"
        case .newestCreated: "Newest First"
        case .oldestCreated: "Oldest First"
        case .longest: "Longest"
        case .shortest: "Shortest"
        case .hardest: "Hardest"
        case .easiest: "Easiest"
        case .mostWordsLeft: "Most Words Left to Learn"
        case .fewestWordsLeft: "Fewest Words Left to Learn"
        }
    }

    // Whether this order compares NoteSortMetrics at all. Title and date orders read the note
    // itself, so the caller can skip deriving metrics (a scan of every saved word) entirely.
    var usesMetrics: Bool {
        switch self {
        case .manual, .titleAToZ, .titleZToA, .recentlyModified, .leastRecentlyModified,
             .newestCreated, .oldestCreated:
            return false
        case .longest, .shortest, .hardest, .easiest, .mostWordsLeft, .fewestWordsLeft:
            return true
        }
    }

    // Grouping used by the sort menu so the thirteen options read as five short sections
    // rather than one long list.
    static let menuGroups: [[NotesSortOrder]] = [
        [.manual],
        [.titleAToZ, .titleZToA],
        [.recentlyModified, .leastRecentlyModified, .newestCreated, .oldestCreated],
        [.longest, .shortest],
        [.hardest, .easiest, .mostWordsLeft, .fewestWordsLeft],
    ]
}
