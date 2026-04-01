import Foundation

// Represents a single kanji writing form for a JMdict entry with priority and element info flags.
nonisolated public struct KanjiForm: Equatable {
    public let text: String
    // Comma-joined ke_pri priority tags (ichi1, news1, spec1, gai1, nf01–nf48, etc.), nil if none.
    public let priority: String?
    // Comma-joined ke_inf information tags (ateji, io, iK, oK, rK, sK), nil if none.
    public let info: String?

    public init(text: String, priority: String?, info: String?) {
        // Stores one kanji element surface with its associated JMdict priority and info tag sets.
        self.text = text
        self.priority = priority
        self.info = info
    }
}
