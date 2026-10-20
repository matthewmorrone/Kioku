import SwiftUI

// Which dictionary word a segment shows when several share its spelling and reading: the user's
// pick if there is one, else the word the neighbouring segments point to (see
// Lexicon.contextuallyPreferredCandidate), else nothing — and the lookup sheet's own rules decide.
extension ReadView {
    // The entry id to treat as chosen for the segment at `location` (UTF-16 offset in the note).
    func chosenEntryID(
        at location: Int,
        surface: String,
        among candidates: [LookupCandidate],
        displayedReading: String?
    ) -> Int64? {
        if let picked = document.chosenEntryIDBySegmentLocation[location] { return picked }
        guard let table = (segmenter as? Segmenter)?.transitionTable,
              let neighbours = neighbourEdges(atLocation: location) else { return nil }
        let sharing = Lexicon.lookupCandidates(candidates, sharingReading: displayedReading)
        return Lexicon.contextuallyPreferredCandidate(
            among: sharing,
            surface: surface,
            previous: neighbours.previous,
            next: neighbours.next,
            table: table
        )?.entry.entryId
    }

    // The segments on either side of the one starting at `location`, found by binary search over the
    // note's ascending edges so the saved-word sweep stays linear. Nil when no segment starts there.
    private func neighbourEdges(atLocation location: Int) -> (previous: LatticeEdge?, next: LatticeEdge?)? {
        let edges = document.segmentEdges
        let target = String.Index(utf16Offset: location, in: document.text)
        var low = 0
        var high = edges.count
        while low < high {
            let middle = (low + high) / 2
            if edges[middle].start < target { low = middle + 1 } else { high = middle }
        }
        guard low < edges.count, edges[low].start == target else { return nil }
        return (low > 0 ? edges[low - 1] : nil, low + 1 < edges.count ? edges[low + 1] : nil)
    }
}
