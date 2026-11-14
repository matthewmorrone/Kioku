import Foundation

// One place a word occurs in a note; `isPointed` marks the one the user starred it from.
nonisolated struct NoteWordOccurrence: Equatable {
    let range: NSRange
    let isPointed: Bool
}

// Finds where a saved word occurs in a note. A saved word keeps only its entry id and the forms it
// was met under, so the spot has to be re-derived from the note: the word page's source lines and
// its jump into the note both ask here, and get the same answer.
nonisolated enum NoteWordLocator {
    // The places the word `entryID` is written in the note: the spot it was starred from first (when
    // `pointed` still holds the same characters at that location), then every other occurrence in text
    // order.
    static func occurrences(
        ofEntry entryID: Int64,
        forms: Set<String>,
        pointed: SourceSpot?,
        in note: Note,
        segmenter: (any TextSegmenting)?
    ) -> [NoteWordOccurrence] {
        var result: [NoteWordOccurrence] = []
        let text = note.content as NSString
        if let pointed, pointed.noteID == note.id, pointed.location >= 0 {
            let range = NSRange(location: pointed.location, length: (pointed.surface as NSString).length)
            if NSMaxRange(range) <= text.length, text.substring(with: range) == pointed.surface {
                result.append(NoteWordOccurrence(range: range, isPointed: true))
            }
        }
        for range in ranges(ofEntry: entryID, forms: forms, in: note, segmenter: segmenter)
        where result.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) == false {
            result.append(NoteWordOccurrence(range: range, isPointed: false))
        }
        return result
    }

    // UTF-16 ranges in `note.content` where the word `entryID` is written, in text order.
    // `forms` are the spellings to look for: the entry's own kanji and kana forms plus any surface the
    // word was saved or met under.
    //
    // Resolution runs through the note's persisted segments, so a conjugated occurrence (りりしく for
    // りりしい) is found without it ever having been recorded: a segment counts when the user picked this
    // entry for it, or when its surface, or a lemma the segmenter resolves it to, is one of the forms.
    // Segments whose top lemma is a form win over segments that only list one as a lesser candidate
    // (いった is 言う first, 行く second), so a common homophone doesn't flood the result.
    // With no usable segments or segmenter, or no segment matching, it falls back to a plain search
    // of the note for the forms.
    static func ranges(
        ofEntry entryID: Int64,
        forms: Set<String>,
        in note: Note,
        segmenter: (any TextSegmenting)?
    ) -> [NSRange] {
        let forms = forms.filter { $0.isEmpty == false }
        guard forms.isEmpty == false else { return [] }

        if let segmenter, let segments = note.segments, segments.isEmpty == false,
           segments.map(\.surface).joined() == note.content {
            var chosen: [NSRange] = []
            var primary: [NSRange] = []
            var secondary: [NSRange] = []
            var location = 0
            for segment in segments {
                let range = NSRange(location: location, length: (segment.surface as NSString).length)
                location += range.length
                if let picked = segment.chosenEntryID {
                    if picked == entryID { chosen.append(range) }
                    continue
                }
                if forms.contains(segment.surface) {
                    primary.append(range)
                } else if let top = segmenter.preferredLemma(for: segment.surface), forms.contains(top) {
                    primary.append(range)
                } else if segmenter.lemmaCandidates(for: segment.surface).contains(where: forms.contains) {
                    secondary.append(range)
                }
            }
            let matched = (chosen + (primary.isEmpty ? secondary : primary)).sorted { $0.location < $1.location }
            if matched.isEmpty == false { return matched }
        }
        return literalRanges(of: forms, in: note.content)
    }

    // Every place any of `forms` is written verbatim in `content`, longest form first so a longer
    // spelling isn't also reported as the shorter one inside it. The fallback when no segment matches.
    private static func literalRanges(of forms: Set<String>, in content: String) -> [NSRange] {
        let text = content as NSString
        var found: [NSRange] = []
        for form in forms.sorted(by: { $0.count > $1.count }) {
            var searchRange = NSRange(location: 0, length: text.length)
            while searchRange.length > 0 {
                let hit = text.range(of: form, options: [], range: searchRange)
                if hit.location == NSNotFound { break }
                if found.contains(where: { NSIntersectionRange($0, hit).length > 0 }) == false {
                    found.append(hit)
                }
                let next = hit.location + max(hit.length, 1)
                searchRange = NSRange(location: next, length: text.length - next)
            }
        }
        return found.sorted { $0.location < $1.location }
    }
}
