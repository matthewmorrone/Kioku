import Foundation

// A word beside a kanji run, as the reading counts (ReadingContextTable) see it: its class
// (TransitionClass) and, where the class is not already the word itself, its lemma. The dictionary
// build names gold tokens with this same type through segcli's `count` mode, so the counts and the
// app key a neighbour word the same way.
nonisolated struct ReadingNeighbour: Sendable {
    let className: String
    let lemma: String?

    // Beyond the ends of the text, and across text the dictionary doesn't cover.
    static let boundary = ReadingNeighbour(className: TransitionClass.boundary, lemma: nil)

    // The lemma a neighbour word is counted under: the segmenter's preferred lemma for its surface,
    // or the surface itself. Nil for BOUNDARY and for a class that is the word itself (w:の), whose
    // class already says everything the word would, and for a lemma that can't be written in the
    // counts' "key=count" lists (whitespace or "=").
    static func lemma(of surface: String, className: String, segmenter: TextSegmenting) -> String? {
        guard className != TransitionClass.boundary, className.hasPrefix("w:") == false else { return nil }
        let lemma = segmenter.preferredLemma(for: surface) ?? surface
        guard lemma.isEmpty == false, lemma.contains("=") == false, lemma.contains(where: \.isWhitespace) == false else {
            return nil
        }
        return lemma
    }

    // The key the counts list this neighbour's word under: class and lemma, tab-joined (a conjugating
    // class carries the ending, so 書いて and 書いた count apart). Nil without a lemma.
    var wordKey: String? { lemma.map { className + "\t" + $0 } }
}
