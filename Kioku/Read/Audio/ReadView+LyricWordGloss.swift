import Foundation

// The dictionary meanings behind the lyrics card's word bubbles (LyricsView+WordBubbles), supplied
// to the card as its dictionaryGloss so the lexical lookup stays on the Read side.
extension ReadView {
    // A lyric word's meaning for the lyrics card's word bubbles: the first gloss of the entry the
    // lookup sheet would show for it there (displayedDictionaryEntry), so the bubble and the sheet
    // agree. Where the sheet leaves the word unpicked (kana あなた: 貴方, 彼方 both read あなた), the
    // likeliest word's meaning alone — "you / beyond" is more than a bubble should say. Nil for
    // words with no entry. A negative form's meaning is negated.
    func lyricWordGloss(at location: Int, surface: String) -> String? {
        guard let entry = displayedDictionaryEntry(forSurface: surface, at: location)
                ?? unpickedLyricCandidates(forSurface: surface, at: location).first,
              let lemmaGloss = entry.senses.first(where: { $0.glosses.isEmpty == false })?.glosses.first else { return nil }
        let gloss = inflectedLyricGloss(lemmaGloss, surface: surface, entry: entry)
        // A parenthesized gloss is qualifying itself — too much for a bubble and usually the wrong
        // sense (LyricsView.shortGloss drops it too).
        return gloss.contains(where: { "()（）".contains($0) }) ? nil : gloss
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
