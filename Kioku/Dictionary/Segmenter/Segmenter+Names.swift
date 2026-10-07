import Foundation

// Proper names in the lattice. JMdict has no 田中 or スティーヴン, so without these the path search
// can only cut a name into the words it happens to contain (田|中). Name edges come from JMnedict
// (nameSurfaces) and are added only where no dictionary edge already spans the same text, so a name
// never displaces a word JMdict spells the same way; the path search weighs a name against the
// pieces on cost like any other edge. A katakana name must be the whole katakana run: JMnedict has
// short katakana names (パル, スミ, タイラ) that would otherwise cut unknown loanwords apart
// (パル|ミンツァ).
extension Segmenter {
    // The usual reading of `surface` when it is one of the lattice's names; see TextSegmenting.
    func nameReading(for surface: String) -> String? {
        guard nameSurfaces.contains(surface) else { return nil }
        return nameReadingLookup?(surface)
    }

    // Every name spelling that starts at `index`, as a lattice edge, except spans `alreadyEndingAt`
    // shows the dictionary already covers. Stops at a boundary character, since a name never
    // spans punctuation or whitespace.
    func nameEdges(in text: String, startingAt index: String.Index, alreadyEndingAt: Set<String.Index>) -> [LatticeEdge] {
        guard longestNameSurface >= 2 else { return [] }
        var edges: [LatticeEdge] = []
        var end = index
        var length = 0
        while length < longestNameSurface, end < text.endIndex, Self.boundaryCharacters.contains(text[end]) == false {
            end = text.index(after: end)
            length += 1
            guard length >= 2, alreadyEndingAt.contains(end) == false else { continue }
            let surface = String(text[index..<end])
            guard nameSurfaces.contains(surface) else { continue }
            if ScriptClassifier.isPureKatakana(surface), isInsideLongerKatakanaRun(index..<end, in: text) { continue }
            var edge = LatticeEdge(start: index, end: end, surface: surface)
            edge.isDictionaryMatch = true
            edge.partOfSpeech = PartOfSpeech.noun.bit
            edge.frequencyScore = SegmenterScoring.nameScore
            edges.append(edge)
        }
        return edges
    }
}
