import Foundation

// Turns notes and saved words into SpotlightDocuments.
nonisolated enum SpotlightDocumentBuilder {
    static let summaryLimit = 140
    static let bodyLimit = 5000

    // A note result: its title, a one-line preview, and the first part of its text as searchable body.
    @MainActor
    static func document(for note: Note) -> SpotlightDocument {
        let flattened = note.content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        return SpotlightDocument(
            identifier: .note(id: note.id),
            title: note.resolvedTitle,
            summary: String(flattened.prefix(summaryLimit)),
            keywords: ["Kioku", "note"],
            bodyText: flattened.isEmpty ? nil : String(flattened.prefix(bodyLimit)),
            modifiedAt: note.modifiedAt
        )
    }

    // A saved-word result. The reading and meanings come from WordCardContentResolver — the same
    // card content flashcards show — so Spotlight never disagrees with them; `content` is nil
    // when the dictionary isn't available, and the result then carries just the surface.
    static func document(for word: SavedWord, content: WordCardContent?) -> SpotlightDocument {
        let reading = content?.kana
        let meanings = content?.meanings ?? []
        var summaryParts: [String] = []
        if let reading, reading != word.surface { summaryParts.append(reading) }
        if meanings.isEmpty == false { summaryParts.append(meanings.joined(separator: "; ")) }
        var keywords = ["Kioku", "word", word.surface]
        keywords.append(contentsOf: [content?.kanji, reading].compactMap { $0 })
        keywords.append(contentsOf: meanings)
        return SpotlightDocument(
            identifier: .word(entryID: word.canonicalEntryID),
            title: word.surface,
            summary: summaryParts.joined(separator: " — "),
            keywords: keywords,
            bodyText: nil,
            modifiedAt: word.savedAt
        )
    }
}
