import Foundation

// Finds a sentence from one of a saved word's source notes containing its surface, for
// sentence-context Fill in the Blank questions — the reverse of what Cloze does (Cloze picks a
// random word out of an already-chosen sentence; this finds a sentence for an already-known word).
// Reuses SentenceRangeResolver, Cloze's sentence splitter, rather than re-implementing sentence
// splitting. `nonisolated` since it's pure, stateless text search — callable from any context,
// including plain (non-`@MainActor`) unit tests.
nonisolated enum SentenceBlankResolver {
    // One blanked sentence: the text immediately before and after the word's surface, so a caller
    // can render "before␣___␣after" and grade a typed answer against `surface`.
    struct Blank: Equatable {
        let before: String
        let surface: String
        let after: String
    }

    // Searches `word`'s source notes (in `sourceNoteIDs` order) for the first sentence containing
    // its surface, returning nil if none of its source notes are found in `notes` (e.g. deleted
    // since the word was saved) or none of their sentences contain the surface (e.g. the note's
    // text was edited since). Only the first match is used — a word appearing multiple times isn't
    // disambiguated further in this first pass.
    static func findBlank(for word: SavedWord, notes: [Note]) -> Blank? {
        guard word.surface.isEmpty == false else { return nil }
        let notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        for noteID in word.sourceNoteIDs {
            guard let note = notesByID[noteID], note.content.isEmpty == false else { continue }
            let nsContent = note.content as NSString
            for range in SentenceRangeResolver.sentenceRanges(in: nsContent) {
                let sentence = nsContent.substring(with: range) as NSString
                let wordRange = sentence.range(of: word.surface)
                guard wordRange.location != NSNotFound else { continue }
                let before = sentence.substring(to: wordRange.location)
                let after = sentence.substring(from: wordRange.location + wordRange.length)
                return Blank(before: before, surface: word.surface, after: after)
            }
        }
        return nil
    }
}
