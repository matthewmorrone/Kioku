import Foundation

// The identity of one Spotlight result. Words are keyed by canonical_entry_id and notes by their
// UUID, in separate domains, so deleting a note only ever removes note results and never touches a
// saved word's.
nonisolated enum SpotlightIdentifier: Equatable, Hashable {
    case word(entryID: Int64)
    case note(id: UUID)

    static let wordDomain = "kioku.word"
    static let noteDomain = "kioku.note"
    private static let wordPrefix = "word:"
    private static let notePrefix = "note:"

    // The string handed to CoreSpotlight as the item's uniqueIdentifier.
    var rawValue: String {
        switch self {
        case .word(let entryID): return Self.wordPrefix + String(entryID)
        case .note(let id): return Self.notePrefix + id.uuidString
        }
    }

    // The domain the item is indexed under, so a whole kind can be cleared at once.
    var domain: String {
        switch self {
        case .word: return Self.wordDomain
        case .note: return Self.noteDomain
        }
    }

    // Parses the identifier CoreSpotlight returns when the user taps a result; nil for anything
    // that isn't one of ours.
    init?(rawValue: String) {
        if rawValue.hasPrefix(Self.wordPrefix), let id = Int64(rawValue.dropFirst(Self.wordPrefix.count)) {
            self = .word(entryID: id)
        } else if rawValue.hasPrefix(Self.notePrefix), let id = UUID(uuidString: String(rawValue.dropFirst(Self.notePrefix.count))) {
            self = .note(id: id)
        } else {
            return nil
        }
    }
}
