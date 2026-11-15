import Foundation

// Unknown hiragana words (ぱいぽ, ぐわっはっは, にょっほっほ) have no lattice edge, so the path search
// covers them with stray one- and two-kana pieces: ぱ|い|ぽ. This pass runs on the chosen path and
// folds such pieces back into one segment, within the stretch between spaces and punctuation.
extension Segmenter {
    // Why: a made-up word the dictionary has never seen should come out as one unit, not a string of
    // stray kana. Two or more adjacent fragments merge; a single function kana ending the stretch
    // (the は of ぐわっはっは) joins them. A function kana in the middle of a stretch (の in ぱいぽの…)
    // is never a fragment, so it is never absorbed and real particles keep their own segments.
    func mergingFragmentRuns(in path: [LatticeEdge], of text: String) -> [LatticeEdge] {
        var result: [LatticeEdge] = []
        result.reserveCapacity(path.count)
        var index = 0
        while index < path.count {
            guard isKanaFragment(path[index]) else {
                result.append(path[index])
                index += 1
                continue
            }
            var runEnd = index
            while runEnd < path.count, isKanaFragment(path[runEnd]) { runEnd += 1 }
            guard runEnd - index >= 2 else {
                result.append(path[index])
                index += 1
                continue
            }
            // A lone function kana that is the last thing before a space, punctuation or the end
            // would otherwise dangle (ぐわっはっ|は): it belongs to the unknown word.
            if runEnd < path.count, isLoneKanaEndingStretch(path[runEnd], in: text) { runEnd += 1 }
            let start = path[index].start
            let end = path[runEnd - 1].end
            result.append(LatticeEdge(start: start, end: end, surface: String(text[start..<end])))
            index = runEnd
        }
        return result
    }

    // Why: the same test the lattice uses to price a stray kana as junk (loneKanaPenalty,
    // twoKanaPenalty), so "fragment" means what the scorer already calls one.
    private func isKanaFragment(_ edge: LatticeEdge) -> Bool {
        let surface = edge.surface
        guard surface.isEmpty == false,
              surface.allSatisfy({ ScriptClassifier.unknownGrouping(for: $0) == "hiragana" }) else { return false }
        // An unknown hiragana edge is a fragment whatever its length (ょっほっほ).
        if edge.isDictionaryMatch == false { return true }
        guard surface.count <= 2 else { return false }
        let isFunctionWord = transitionTable?.lexical.contains(surface) ?? false
        let isCommonTwoKana = surface.count == 2 && commonKanaSurfaces.contains(surface)
        // A lone kana that the dictionary lists as a counter (ぐ, ぱ) is still a stray piece here; a
        // two-kana counter is a word.
        let isTwoKanaCounter = surface.count == 2 && PartOfSpeech.isCounter(edge.partOfSpeech)
        return isFunctionWord == false && isCommonTwoKana == false && isTwoKanaCounter == false
    }

    // Why: tells the merge whether a one-kana edge sits at the end of its stretch.
    private func isLoneKanaEndingStretch(_ edge: LatticeEdge, in text: String) -> Bool {
        guard edge.surface.count == 1,
              ScriptClassifier.unknownGrouping(for: edge.surface.first!) == "hiragana" else { return false }
        return edge.end == text.endIndex || isSpanBreak(text[edge.end])
    }
}
