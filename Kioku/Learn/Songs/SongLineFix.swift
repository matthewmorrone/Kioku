import Foundation

// One correction a breakdown suggests for its line, parsed from a `**Fix:** <kind> <original> → <replacement>`
// line (SongBreakdownPrompt rules 12 and 13) and offered in the Breakdown's fix list. `original` and
// `replacement` keep the model's markup: kanji runs followed by their reading in brackets for a
// reading fix (見[み]た), words joined by | for a split fix (告げる|風), plain text for a typo.
nonisolated struct SongLineFix: Codable, Equatable, Hashable, Sendable {
    let kind: SongLineFixKind
    let original: String
    let replacement: String

    // Parses the text after the **Fix:** marker ("reading 風[ふう] → 風[かぜ]"); nil when the kind is
    // unknown, an arrow or side is missing, or the two sides don't describe the same kind of change
    // (a reading or split fix that changes the characters, a typo that changes nothing).
    init?(markup: String) {
        let trimmed = markup.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " "),
              let kind = SongLineFixKind(rawValue: trimmed[..<space].lowercased()) else { return nil }
        let body = trimmed[space...]
        guard let arrow = ["→", "->", "⇒"].lazy.compactMap({ body.range(of: $0) }).first else { return nil }
        let original = body[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "`")))
        let replacement = body[arrow.upperBound...].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "`")))
        guard original.isEmpty == false, replacement.isEmpty == false, original != replacement else { return nil }
        self.kind = kind
        self.original = original
        self.replacement = replacement
        switch kind {
        case .reading, .split:
            guard originalSurface == replacementSurface else { return nil }
        case .typo:
            guard originalSurface != replacementSurface else { return nil }
        }
    }

    // The text the fix finds in the line: `original` without readings or word breaks.
    var originalSurface: String { Self.surface(of: original) }

    // The text the line holds after the fix: `replacement` without readings or word breaks.
    var replacementSurface: String { Self.surface(of: replacement) }

    // A reading fix's whole-word reading: each bracketed kanji run replaced by its reading
    // (見[み]た → みた), what the Read tab's reading override takes.
    var replacementReading: String {
        replacement.replacingOccurrences(of: #"[\p{Han}々〆ヵヶ]+\[([^\]]*)\]"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "|", with: "")
    }

    // The previous reading, in the same form, for the fix list's before → after.
    var originalReading: String {
        original.replacingOccurrences(of: #"[\p{Han}々〆ヵヶ]+\[([^\]]*)\]"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "|", with: "")
    }

    // A split fix's words after the fix, in order (告げる風 → ["告げる風"]).
    var replacementWords: [String] {
        Self.surface(of: replacement, keepingBreaks: true).split(separator: "|").map(String.init)
    }

    // The words before the fix, in order.
    var originalWords: [String] {
        Self.surface(of: original, keepingBreaks: true).split(separator: "|").map(String.init)
    }

    // `text` with bracketed readings removed and, unless kept, the | word breaks.
    private static func surface(of text: String, keepingBreaks: Bool = false) -> String {
        let bare = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        return keepingBreaks ? bare : bare.replacingOccurrences(of: "|", with: "")
    }
}
