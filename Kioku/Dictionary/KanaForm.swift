import Foundation

// Represents a single kana reading form for a JMdict entry with priority, info flags, and nokanji marker.
nonisolated public struct KanaForm: Equatable {
    public let text: String
    // Comma-joined re_pri priority tags (ichi1, news1, spec1, gai1, nf01–nf48, etc.), nil if none.
    public let priority: String?
    // Comma-joined re_inf information tags (gikun, ik, ok, uK, sk), nil if none.
    public let info: String?
    // True when this reading does not apply to any kanji form (JMdict re_nokanji flag).
    public let nokanji: Bool

    public init(text: String, priority: String?, info: String?, nokanji: Bool) {
        // Stores one kana element reading with its associated JMdict priority, info tag sets, and nokanji flag.
        self.text = text
        self.priority = priority
        self.info = info
        self.nokanji = nokanji
    }
}
