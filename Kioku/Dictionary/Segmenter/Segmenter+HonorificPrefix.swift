import Foundation

// The honorific お/ご before a verb's stem (おつきあい|ください, お待ち|ください, お読み|になる): the
// prefix and the stem read as one word that behaves like the stem itself. JMdict lists some of these
// as nouns (お付き合い), which prices them like a noun before ください; without an edge of the stem's
// class, a stray prefix-free reading wins instead (すこしのまお|つきあい with まお, 苧).
extension Segmenter {
    // An edge for お/ご + each verb-stem edge right after one, classed and priced as that stem plus
    // one inflection step for the prefix. A stem is a verb surface the deinflector reaches its
    // dictionary form from in exactly one stemRecoveryForms step (付き合い → 付き合う).
    func honorificStemEdges(in text: String, lattice: [LatticeEdge]) -> [LatticeEdge] {
        guard let deinflector else { return [] }
        let stemLabel = Deinflector.normalizedRuleLabel("stemRecoveryForms")
        var added: [LatticeEdge] = []
        for edge in lattice where edge.isDictionaryMatch && edge.start > text.startIndex
            && PartOfSpeech.isVerb(edge.partOfSpeech) && edge.inflectionSteps == 1 {
            let prefixIndex = text.index(before: edge.start)
            guard text[prefixIndex] == "お" || text[prefixIndex] == "ご" else { continue }
            let isStem = deinflector.deinflectionPaths(for: edge.surface).values.contains { paths in
                paths.contains { $0.transitions.count == 1 && $0.transitions[0].label == stemLabel }
            }
            guard isStem else { continue }
            var honorific = LatticeEdge(start: prefixIndex, end: edge.end, surface: String(text[prefixIndex..<edge.end]))
            honorific.lemma = edge.lemma
            honorific.indices = edge.indices
            honorific.partOfSpeech = edge.partOfSpeech
            honorific.isDictionaryMatch = true
            honorific.frequencyScore = edge.frequencyScore
            honorific.inflectionSteps = edge.inflectionSteps + 1
            added.append(honorific)
        }
        return added
    }
}
