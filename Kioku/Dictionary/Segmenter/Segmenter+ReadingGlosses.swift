import Foundation

// Readings written inline in parentheses after a kanji word, as lyrics do: 旋律(おと), 瞳(め),
// 幼(あお)い. The kana inside spell the preceding word's reading, so they are one segment, never
// words of their own: otherwise rare kana spellings come apart into cheaper pieces (お|と).
extension Segmenter {
    // The lattice with each reading gloss reduced to one edge spanning it: the dictionary's edge for
    // the whole gloss when it has one (おと keeps its entries), else a plain edge, and no edge that
    // starts or ends inside it.
    func collapsingReadingGlosses(in edges: [LatticeEdge], of text: String) -> [LatticeEdge] {
        let glosses = readingGlossRanges(in: text)
        guard glosses.isEmpty == false else { return edges }
        var result = edges.filter { edge in
            glosses.contains { gloss in
                (gloss.contains(edge.start) && edge.start != gloss.lowerBound)
                    || (gloss.contains(edge.end) && edge.end != gloss.lowerBound)
                    || (edge.start == gloss.lowerBound && edge.end != gloss.upperBound)
            } == false
        }
        for gloss in glosses where result.contains(where: { $0.start == gloss.lowerBound && $0.end == gloss.upperBound }) == false {
            result.append(LatticeEdge(start: gloss.lowerBound, end: gloss.upperBound, surface: String(text[gloss])))
        }
        return result
    }

    // Ranges of the kana between an opening parenthesis that directly follows a kanji and its
    // closing parenthesis, when everything between them is kana.
    func readingGlossRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            guard character == "(" || character == "（", index > text.startIndex,
                  isKanji(text[text.index(before: index)]),
                  let close = text[next...].firstIndex(where: { $0 == ")" || $0 == "）" }),
                  close > next,
                  ScriptClassifier.isPureKana(String(text[next..<close])) else {
                index = next
                continue
            }
            ranges.append(next..<close)
            index = close
        }
        return ranges
    }

    // Whether a character is a kanji (or 々, which repeats one), so the gloss follows a kanji word.
    private func isKanji(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return character == "々" || ScriptClassifier.isKanjiScalar(scalar)
    }
}
