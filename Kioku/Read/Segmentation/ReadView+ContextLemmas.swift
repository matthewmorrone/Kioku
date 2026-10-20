import SwiftUI

// Reference-type cache for contextLemmaBySurface, held by ReadDocumentState like the other memos
// so the extract-words sheet's body passes don't redo the dictionary sweep. `signature` hashes
// what the answer depends on.
final class ContextLemmaMemo {
    var signature: Int?
    var bySurface: [String: String] = [:]
}

// The dictionary form each ambiguous spelling in the note has HERE, for the extract-words list.
// The list keys its rows, stars and dedupe by lemma, and Segmenter.preferredLemma gives one lemma per
// spelling with no neighbours: 怒り is the verb 怒る or the noun 怒り whichever the sentence means.
// For each spelling that can be several words, this asks the same per-occurrence choice the lookup
// sheet makes (the user's pick, else the neighbouring segments) and returns that word's lemma. A
// spelling is decided by its first occurrence the choice settles; the list is one row per spelling.
extension ReadView {
    // Lemma by edge surface, only for spellings where the note's context named one word. The list
    // falls back to preferredLemma for every other spelling.
    func contextLemmaBySurface() -> [String: String] {
        var hasher = Hasher()
        hasher.combine(document.text.hashValue)
        hasher.combine(document.segmentEdges.count)
        hasher.combine(document.chosenEntryIDBySegmentLocation)
        hasher.combine(document.furiganaBySegmentLocation)
        let signature = hasher.finalize()
        if document.contextLemmaMemo.signature == signature { return document.contextLemmaMemo.bySurface }

        var result: [String: String] = [:]
        if let lexicon {
            var attempts: [String: Int] = [:]
            for edge in document.segmentEdges where edge.isDictionaryMatch {
                let surface = edge.surface
                // One answer per spelling, a few tries at most when the first occurrences are undecided.
                guard result[surface] == nil, attempts[surface, default: 0] < 5,
                      segmenter.lemmaCandidates(for: surface).count > 1 else { continue }
                attempts[surface, default: 0] += 1
                let location = NSRange(edge.start..<edge.end, in: document.text).location
                guard location != NSNotFound else { continue }
                let candidates = lexicon.lookupCandidates(surface: surface)
                guard candidates.count > 1 else { continue }
                let reconstructed = reconstructedReading(for: surface, at: location)
                let displayed = reconstructed.isEmpty
                    ? ReadingVariants.orderedReadings(
                        surface: surface,
                        lexicon: lexicon,
                        segmenter: segmenter,
                        surfaceReadingData: surfaceReadingData
                    ).first
                    : reconstructed
                let chosen = chosenEntryID(at: location, surface: surface, among: candidates, displayedReading: displayed)
                if let shown = Lexicon.shownLookupCandidate(among: candidates, chosenEntryID: chosen, displayedReading: displayed) {
                    result[surface] = shown.lemma
                }
            }
        }
        document.contextLemmaMemo.signature = signature
        document.contextLemmaMemo.bySurface = result
        return result
    }
}
