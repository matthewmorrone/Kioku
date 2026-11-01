import Foundation

// Builds the tab-separated text Anki's importer reads. The `#` header lines are Anki's own
// file-header syntax: they set the separator, turn HTML off so the text is taken literally, name
// the columns, and say which column holds tags — so a re-import maps the fields without prompting.
nonisolated enum AnkiTSVBuilder {
    static let columns = ["Front", "Back", "Reading", "Notes", "Tags"]

    // One row per word. The headword and meanings come from `content`, the same card content
    // flashcards show; a word the dictionary no longer knows exports its saved surface with no back.
    static func row(for word: SavedWord, content: WordCardContent?, listNames: [String]) -> AnkiRow {
        let reading = content?.kana ?? ""
        let headword = content?.kanji ?? word.surface
        return AnkiRow(
            front: headword,
            back: (content?.meanings ?? []).joined(separator: "; "),
            reading: reading == headword ? "" : reading,
            notes: word.personalNote ?? "",
            tags: listNames
        )
    }

    // The whole file: header lines, then one line per row.
    static func build(rows: [AnkiRow]) -> String {
        var lines = [
            "#separator:tab",
            "#html:false",
            "#columns:" + columns.joined(separator: "\t"),
            "#tags column:\(columns.count)",
        ]
        for row in rows {
            let fields = [row.front, row.back, row.reading, row.notes, row.tags.map(tag).joined(separator: " ")]
            lines.append(fields.map(sanitized).joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // Tabs would split a field and line breaks would end the row, so both become spaces.
    static func sanitized(_ field: String) -> String {
        field
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // Anki separates tags with spaces, so a list name with spaces becomes one underscored tag.
    static func tag(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: "_")
    }
}
