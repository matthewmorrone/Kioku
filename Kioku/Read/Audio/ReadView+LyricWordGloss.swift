import Foundation

// The dictionary meanings behind the lyrics card's word bubbles (LyricsView+WordBubbles), supplied
// to the card as its dictionaryGloss so the lexical lookup stays on the Read side.
extension ReadView {
    // A lyric word's meaning for the lyrics card's word bubbles: the first gloss of the entry the
    // lookup sheet would show for it there (displayedDictionaryEntry), so the bubble and the sheet
    // agree. Where the sheet leaves the word unpicked (kana なりたい: 成る, 鳴る… all read なる), the
    // two likeliest words' meanings side by side, "to become / to ring". Nil for particles — their
    // glosses describe grammar — counting, as the segmenter does (TransitionClass), any spelling
    // that can be one (は, not 歯 "tooth"); nil for katakana words, whose loanword meaning the
    // reader can sound out; and nil for words with no entry. A negative form's meaning is negated.
    func lyricWordGloss(at location: Int, surface: String) -> String? {
        guard ScriptClassifier.isPureKatakana(surface) == false,
              PartOfSpeech.isParticle(dictionaryStore?.posBits(forSurface: surface) ?? 0) == false else { return nil }
        let entries: [DictionaryEntry]
        if let entry = displayedDictionaryEntry(forSurface: surface, at: location) {
            entries = [entry]
        } else {
            entries = Array(unpickedLyricCandidates(forSurface: surface, at: location).prefix(2))
        }
        var glosses: [String] = []
        for entry in entries {
            guard let lemmaGloss = entry.senses.first(where: { $0.glosses.isEmpty == false })?.glosses.first else { continue }
            let gloss = inflectedLyricGloss(lemmaGloss, surface: surface, entry: entry)
            guard glosses.contains(gloss) == false else { continue }
            glosses.append(gloss)
        }
        return glosses.isEmpty ? nil : glosses.joined(separator: " / ")
    }

    // The lemma's meaning turned into the sung form's where the form flips it: 足りない under 足りる
    // reads "not sufficient", not "to be sufficient". Only negation is carried over (tense and
    // politeness don't change what the word means in a bubble), and only when `entry` is the lemma —
    // an entry spelled like the surface (足りない's own entry) already means the whole form.
    private func inflectedLyricGloss(_ gloss: String, surface: String, entry: DictionaryEntry) -> String {
        let definesSurface = entry.kanjiForms.contains { $0.text == surface } || entry.kanaForms.contains { $0.text == surface }
        guard definesSurface == false,
              let chain = lexicon?.inflectionInfo(surface: surface)?.chain,
              InflectionFormNames.isNegative(chain) else { return gloss }
        var base = gloss
        for prefix in ["to be ", "to "] where base.hasPrefix(prefix) {
            base.removeFirst(prefix.count)
            break
        }
        return "not " + base
    }

    // The words sharing a lyric word's shown reading, in order: the sheet's list when it's unpicked.
    private func unpickedLyricCandidates(forSurface surface: String, at location: Int) -> [DictionaryEntry] {
        guard let lexicon else { return [] }
        let reconstructed = reconstructedReading(for: surface, at: location)
        let displayed = reconstructed.isEmpty
            ? ReadingVariants.orderedReadings(
                surface: surface,
                lexicon: lexicon,
                segmenter: segmenter,
                surfaceReadingData: surfaceReadingData
            ).first
            : reconstructed
        return Lexicon.lookupCandidates(lexicon.lookupCandidates(surface: surface), sharingReading: displayed).map(\.entry)
    }
}
