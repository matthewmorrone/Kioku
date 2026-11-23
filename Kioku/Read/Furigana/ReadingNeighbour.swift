import Foundation

// A word beside a kanji run, as the reading model (ReadingContextTable) sees it: its class
// (TransitionClass), its lemma where the class is not already the word itself, and `word`, the lemma or
// else the surface, which is what the word vectors are keyed by. The dictionary build names gold tokens
// with this same type through segcli's `count` mode, so the model trains on the words the app finds.
nonisolated struct ReadingNeighbour: Sendable {
    let className: String
    let lemma: String?
    // The lemma, or the surface where there is none; nil for BOUNDARY.
    let word: String?

    // Beyond the ends of the text, and across text the dictionary doesn't cover.
    static let boundary = ReadingNeighbour(className: TransitionClass.boundary, lemma: nil, word: nil)

    // The neighbour for a dictionary-matched `surface` of class `className`.
    init(surface: String, className: String, segmenter: TextSegmenting) {
        let lemma = Self.lemma(of: surface, className: className, segmenter: segmenter)
        self.init(className: className, lemma: lemma, word: lemma ?? surface)
    }

    // Memberwise, for `boundary`.
    private init(className: String, lemma: String?, word: String?) {
        self.className = className
        self.lemma = lemma
        self.word = word
    }

    // The lemma a neighbour word is counted under: the segmenter's preferred lemma for its surface,
    // or the surface itself. Nil for BOUNDARY and for a class that is the word itself (w:の), whose
    // class already says everything the word would, and for a lemma that can't be written in the
    // build's space-separated token lines (whitespace or "=").
    static func lemma(of surface: String, className: String, segmenter: TextSegmenting) -> String? {
        guard className != TransitionClass.boundary, className.hasPrefix("w:") == false else { return nil }
        let lemma = segmenter.preferredLemma(for: surface) ?? surface
        guard lemma.isEmpty == false, lemma.contains("=") == false, lemma.contains(where: \.isWhitespace) == false else {
            return nil
        }
        return lemma
    }
}
