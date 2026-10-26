import Foundation

// The smaller words a segment is made of, for the lookup sheet and the word detail page: 歌い続けてゆく
// is 歌う + 続ける + ゆく. The pieces come from the segmenter's own path search (see
// Segmenter.constituentSegments), applied again to every piece that is itself built from smaller
// ones; each piece is then named by its dictionary form.
extension Lexicon {
    // A piece is a word of its own, not a compound, when it is a plain inflection of one lemma:
    // 食べた is 食べる conjugated, not 食べ + た, and 歌い is 歌う's stem. A form that folds helper words
    // in (歩いてゆこう) is a compound.
    func isPlainInflection(_ surface: String) -> Bool {
        guard let info = inflectionInfo(surface: surface), info.lemma != surface else { return false }
        return helperWords(surface: surface, lemma: info.lemma).isEmpty
    }

    // The segments `surface` is built from, outermost split first and each piece split again where it
    // is itself a compound, as their surfaces in reading order; nil when the surface is a single word.
    // `maxMargin` bounds how much dearer than the whole word the split may be (a lone word like 学校
    // costs far more to cut than a compound like 巡り会う).
    // Each piece is strictly shorter than its surface (a split has two or more pieces covering it), so
    // the recursion ends on its own: it stops at pieces that are single words, not at any fixed depth.
    public func constituentSurfaces(of surface: String, maxMargin: Int) -> [String]? {
        guard isPlainInflection(surface) == false,
              let split = segmenter.constituentSegments(of: surface), split.margin <= maxMargin else { return nil }
        // A word written as single kanji side by side (二人 ふたり, 今日) is one word with its own reading,
        // not a compound worth taking apart: its pieces carry no meaning of their own to link to.
        if split.pieces.allSatisfy({ $0.surface.count == 1 && ScriptClassifier.containsKanji($0.surface) }) { return nil }
        return split.pieces.flatMap { piece in
            constituentSurfaces(of: piece.surface, maxMargin: maxMargin) ?? [piece.surface]
        }
    }

    // The dictionary form each of `pieces` is named by. A piece followed by another word is a verb's
    // stem when the deinflector reaches a verb from it in one stem-recovery step (巡り → 巡る, 思い → 思う
    // before 会う / 出す), even when the stem is also a noun of its own; that verb names it. Otherwise
    // the piece's usual lemma, or the piece itself.
    public func constituentLemmas(of pieces: [String]) -> [String] {
        let stemLabel = Deinflector.normalizedRuleLabel("stemRecoveryForms")
        return pieces.enumerated().map { index, piece in
            if index < pieces.count - 1 {
                let paths = deinflector.deinflectionPaths(for: piece)
                let stemLemmas = paths.filter { lemma, found in
                    lemma != piece && found.contains { $0.transitions.count == 1 && $0.transitions[0].label == stemLabel }
                        && lookupEntries(for: lemma).isEmpty == false
                }.keys.sorted()
                if let stemLemma = stemLemmas.first { return stemLemma }
            }
            return segmenter.preferredLemma(for: piece) ?? piece
        }
    }

    // How much dearer than the whole word a split may be and still count as the word being made of
    // smaller words: compounds measured up to ~3300 centi-nats (図書館), single words from ~3900 (大人).
    static let maxConstituentMargin = 3500

    // The lemma line both screens show under the headword: the smaller words the segment is made of,
    // each by its dictionary form (歌う + 続ける + ゆく, 巡る + 会う, 科学 + 的), else the lemma with the
    // helper words its deinflection folds in (起こる + そう), else nil for a single word. One entry
    // point, so the lookup sheet and the word detail page cannot disagree about what a segment holds.
    public func lemmaLine(surface: String) -> String? {
        if let pieces = constituentSurfaces(of: surface, maxMargin: Self.maxConstituentMargin) {
            let lemmas = constituentLemmas(of: pieces)
            if lemmas.count > 1 { return lemmas.joined(separator: " + ") }
        }
        if let inflected = constituentsOfInflectedLemma(of: surface) {
            return constituentLemmas(of: inflected.pieces).joined(separator: " + ")
        }
        return lemmaWithHelpers(surface: surface)
    }

    // A plain inflection of a lemma that is itself made of several words (眠りについて, the te-form of
    // 眠りにつく = 眠り + に + つく): the lemma and its pieces. Nil when the surface is not a plain
    // inflection, or its lemma is a single word (食べた → 食べる).
    func constituentsOfInflectedLemma(of surface: String) -> (lemma: String, pieces: [String])? {
        guard isPlainInflection(surface), let lemma = inflectionInfo(surface: surface)?.lemma,
              let pieces = constituentSurfaces(of: lemma, maxMargin: Self.maxConstituentMargin) else { return nil }
        return (lemma, pieces)
    }
}
