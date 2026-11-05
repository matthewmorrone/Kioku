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
        guard let entry = lyricBubbleEntry(at: location, surface: surface),
              let lemmaGloss = bubbleGloss(from: entry.senses.first(where: { $0.glosses.isEmpty == false })?.glosses ?? []) else { return nil }
        let gloss = inflectedLyricGloss(lemmaGloss, surface: surface, entry: entry)
        return gloss
    }

    // The longest first gloss a bubble shows as is.
    private static let maxBubbleGlossLength = 30

    // Why: a bubble holds a word, not a sentence. A sense's first gloss is kept when short; a long one
    // ("standing on tiptoe and stretching one's back to make oneself taller") gives way to the
    // shortest gloss of the same sense ("stretching oneself").
    private func bubbleGloss(from glosses: [String]) -> String? {
        guard let first = glosses.first else { return nil }
        guard first.count > Self.maxBubbleGlossLength else { return first }
        return glosses.min(by: { $0.count < $1.count }) ?? first
    }

    // The state the bubble meanings are read from: the lexicon and the reading data in use. LyricsView rebuilds its cached bubbles when this changes.
    var lyricGlossRevision: Int {
        var hasher = Hasher()
        hasher.combine(lexicon.map(ObjectIdentifier.init))
        hasher.combine(ObjectIdentifier(surfaceReadingData))
        hasher.combine(dictionaryStore != nil)
        return hasher.finalize()
    }

    // Whether a lyric word's bubble would give a particle's meaning, for the Particle Meanings
    // setting: judged by the sense the bubble shows (lyricBubbleEntry), so は given as 歯 "tooth"
    // keeps its bubble while the topic marker は loses it. Surfaces in KanaData.nonParticleWords
    // (まで, ほど) are never particles here, whatever the dictionary tags them.
    func isLyricParticle(at location: Int, surface: String) -> Bool {
        if KanaData.nonParticleWords.contains(surface) { return false }
        guard let sense = lyricBubbleEntry(at: location, surface: surface)?.senses.first(where: { $0.glosses.isEmpty == false }) else {
            return false
        }
        return PartOfSpeech.isParticle(PartOfSpeech.bits(from: sense.pos))
    }

    // The entry a lyric word's bubble speaks for: the one the lookup sheet shows, else, where the
    // sheet leaves the word unpicked, the spelling's common word among those sharing its reading —
    // the dictionary's canonical entry for it (resolvedDictionaryEntry: function words first for
    // kana, then frequency), so kana の is the particle and not 野 read の. The first candidate only
    // when the canonical entry isn't one of them.
    private func lyricBubbleEntry(at location: Int, surface: String) -> DictionaryEntry? {
        if let shown = displayedDictionaryEntry(forSurface: surface, at: location) { return shown }
        let candidates = unpickedLyricCandidates(forSurface: surface, at: location)
        if let canonical = resolvedDictionaryEntry(forSurface: surface),
           let common = candidates.first(where: { $0.entryId == canonical.entryId }) {
            return common
        }
        return candidates.first
    }

    // Whether a lyric word is a loanword in katakana (ベイビー, ドア, キスした), for the English Words
    // setting: its katakana stem's entry is spelled only in katakana. A Japanese word written in
    // katakana (キラキラ, ダメ, ウソ) has a hiragana or kanji spelling too and counts as Japanese. A
    // katakana stem the dictionary doesn't know in katakana or in hiragana is taken for a loanword —
    // lyrics write Japanese words in katakana for emphasis (ゼッタイ for 絶対) that the dictionary
    // only spells ぜったい. Never a word the user defined themselves (a Custom Word with its own
    // meaning): they added it to see it, so the English Words option doesn't hide it.
    func isLyricLoanword(_ surface: String) -> Bool {
        guard ScriptClassifier.isKatakanaWord(surface),
              let stem = ScriptClassifier.leadingKatakanaPrefix(of: surface) else { return false }
        let isCustomWord = customWordStore.words.contains { word in
            word.sameAsEntSeq == nil && (word.kana + word.kanji).contains { stem == $0 || surface == $0 }
        }
        if isCustomWord { return false }
        // The lexicon also resolves a katakana spelling through its hiragana one (ゼッタイ → ぜったい),
        // which the plain store lookup doesn't; without that, every emphasis spelling read as a loanword.
        guard let entry = resolvedDictionaryEntry(forSurface: stem) ?? lexicon?.lookupCandidates(surface: stem).first?.entry else { return true }
        return entry.kanjiForms.isEmpty && entry.kanaForms.allSatisfy { ScriptClassifier.isPureKatakana($0.text) }
    }

    // The lemma's meaning turned into the sung form's, so a bubble never shows the plain verb for an
    // inflected one: 足りない under 足りる reads "not sufficient", 食べたい "want to eat", 食べた "eat
    // (past)". A guess already stored for the whole form (the lookup sheet's composite gloss) wins.
    // Only when `entry` is the lemma — an entry spelled like the surface (足りない's own entry)
    // already means the whole form.
    private func inflectedLyricGloss(_ gloss: String, surface: String, entry: DictionaryEntry) -> String {
        let definesSurface = entry.kanjiForms.contains { $0.text == surface } || entry.kanaForms.contains { $0.text == surface }
        guard definesSurface == false, let info = lexicon?.inflectionInfo(surface: surface) else { return gloss }
        if let stored = GuessedGlossStore.composite.gloss(for: surface, in: info.lemma) { return stored }
        return InflectionFormNames.applying(info.chain, to: gloss)
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
