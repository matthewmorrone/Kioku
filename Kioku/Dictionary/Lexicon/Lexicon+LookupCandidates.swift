import Foundation

// Every dictionary word a surface can be, for the lookup sheet's list of possibilities. A kana
// form is often several words at once — いった is the past of 言う, 行く and godan 要る — and the
// kana is the same for all of them, so the reading arrows cannot tell them apart.
nonisolated extension Lexicon {
    // How many possibilities the sheet lists; past this the rows are rare homographs.
    static let maxLookupCandidates = 6

    // The words `surface` can be, best first. The first row is the engine's own pick (its top lemma's
    // best entry); after it, each other lemma's best entry in lemma order, then the remaining entries
    // by frequency. "Best" is the most frequent, except that for a kana lemma the words written in
    // kana come first and are listed even without a rank (isWrittenInKana). An entry only counts when it conjugates the way the
    // chain reaching it claims: いった reaches いる by a godan rule, so 要る is listed and 居る is not.
    // The surface's own headwords are always possibilities too, even when the engine reads the form
    // as a conjugation: きた is 来る's past and also 北.
    func lookupCandidates(surface: String) -> [LookupCandidate] {
        var (lemmas, pathsByLemma) = admittedLemmasAndPaths(for: surface)
        if lemmas.contains(where: { $0.lemma == surface }) == false {
            lemmas.append((lemma: surface, depth: 0))
        }
        var leaders: [LookupCandidate] = []
        var others: [LookupCandidate] = []
        var seenEntryIDs = Set<Int64>()
        let surfaceIsWord = lookupEntries(for: surface).isEmpty == false
        for (lemma, _) in lemmas {
            // A lemma reached by folding in a helper word (思い出す → 思う + 出す) is one of the
            // surface's parts, not another word it could be, when the surface is a word itself.
            if surfaceIsWord, lemma != surface,
               deinflector.helperWords(from: pathsByLemma, targetLemma: lemma).isEmpty == false {
                continue
            }
            let grammars = deinflector.endingGrammars(from: pathsByLemma, targetLemma: lemma)
            let entries = lookupEntries(for: lemma)
                .filter { entry in
                    grammars.isEmpty
                        || ConjugationClass.grammars(forPOSStrings: entry.senses.compactMap(\.pos)).isDisjoint(with: grammars) == false
                }
                .filter { seenEntryIDs.insert($0.entryId).inserted }
                .sorted { lhs, rhs in
                    // A kana surface is first the words written in kana: the copula だ (no kanji
                    // form, and no frequency rank) before 打 and 駄, which are only read だ.
                    // A kana function word first of all: や is the particle before 嫌 (uk only as
                    // いや), agreeing with the store's canonical pick for the surface.
                    let lhsFunction = isKanaFunctionWord(lhs, surface: lemma)
                    let rhsFunction = isKanaFunctionWord(rhs, surface: lemma)
                    if lhsFunction != rhsFunction { return lhsFunction }
                    let lhsKana = isWrittenInKana(lhs, surface: lemma), rhsKana = isWrittenInKana(rhs, surface: lemma)
                    if lhsKana != rhsKana { return lhsKana }
                    return (lhs.frequencyRank ?? Int.max) < (rhs.frequencyRank ?? Int.max)
                }
            // The conjugation from this lemma to the surface, applied to each entry's own kana.
            let transitions = lemma == surface ? nil : deinflector.bestTransitions(from: pathsByLemma, targetLemma: lemma)
            for (index, entry) in entries.enumerated() {
                var readings: [String] = []
                for kana in entry.kanaForms.map(\.text) {
                    let projected = transitions.map { applySurfaceTransitions(to: kana, transitions: $0) } ?? kana
                    if let projected, readings.contains(projected) == false { readings.append(projected) }
                }
                // A katakana spelling of a hiragana reading (人 ひと / ヒト) is the same reading, not
                // another arrow stop.
                readings = readings.filter { reading in
                    let hiragana = KanaNormalizer.katakanaToHiragana(reading)
                    return hiragana == reading || readings.contains(hiragana) == false
                }
                // Kana text is its own reading: いった can't be read ゆった (言う's ゆう form).
                if ScriptClassifier.containsKanji(surface) == false {
                    readings = readings.filter { $0 == surface }
                }
                let candidate = LookupCandidate(
                    lemma: lemma,
                    headword: entry.kanjiForms.first?.text ?? entry.kanaForms.first?.text ?? lemma,
                    reading: entry.kanaForms.first?.text ?? lemma,
                    entry: entry,
                    surfaceReadings: readings
                )
                if index == 0 {
                    leaders.append(candidate)
                } else if entry.frequencyRank != nil || isWrittenInKana(entry, surface: lemma)
                            || isHomograph(entry, of: lemma) {
                    others.append(candidate)
                }
            }
        }
        // A kana-only function word (the particle や) has no frequency rank, so ranking alone sinks it
        // below every kanji homophone and the row cap drops it; it is too likely a reading to lose.
        others.sort { lhs, rhs in
            let lhsFunction = isKanaFunctionWord(lhs.entry, surface: surface)
            let rhsFunction = isKanaFunctionWord(rhs.entry, surface: surface)
            if lhsFunction != rhsFunction { return lhsFunction }
            return (lhs.entry.frequencyRank ?? Int.max) < (rhs.entry.frequencyRank ?? Int.max)
        }
        return Array((leaders + others).prefix(Self.maxLookupCandidates))
    }

    // True when the entry writes the kanji `lemma` as an everyday spelling: a homograph (抱く read
    // いだく, だく or うだく), kept however rare so its reading is one of the sheet's arrow stops.
    func isHomograph(_ entry: DictionaryEntry, of lemma: String) -> Bool {
        ScriptClassifier.containsKanji(lemma) && entry.kanjiForms.contains {
            $0.text == lemma && DictionaryEntry.kanjiFormIsNonEveryday(info: $0.info) == false
        }
    }

    // True when `surface` is kana and the entry is a kana-only particle, copula or auxiliary — the
    // same functional parts of speech the dictionary store ranks first for a kana lookup.
    private func isKanaFunctionWord(_ entry: DictionaryEntry, surface: String) -> Bool {
        guard ScriptClassifier.containsKanji(surface) == false, entry.kanjiForms.isEmpty else { return false }
        return entry.senses.contains { sense in
            (sense.pos ?? "").split(separator: ",").contains { tag in
                tag == "prt" || tag == "cop" || tag == "aux" || tag.hasPrefix("aux-")
            }
        }
    }

    // True when `surface` is kana and the entry is a word normally written that way: no kanji form,
    // or JMdict's "usually written using kana alone" (uk) on a sense. Such entries are what a kana
    // surface most likely is, ranked or not; a kanji word that merely reads the same is not.
    private func isWrittenInKana(_ entry: DictionaryEntry, surface: String) -> Bool {
        guard ScriptClassifier.containsKanji(surface) == false else { return false }
        if entry.kanjiForms.isEmpty { return true }
        return entry.senses.contains { ($0.misc ?? "").split(separator: ",").contains("uk") }
    }

    // The candidate to show before the user picks: the only word the dictionary marks as in common
    // use when there is one (消して → 消す over the literary 消する), else the first, which the list
    // already orders as the likeliest — the particle や, 言う for いった. The others stay a tap away.
    static func preferredLookupCandidate(among candidates: [LookupCandidate]) -> LookupCandidate? {
        let common = candidates.filter { $0.entry.hasPriorityForm }
        return common.count == 1 ? common[0] : candidates.first
    }

    // The words a reading leaves undecided: the candidates read that way (怒り read いかり → the noun
    // 怒り and 怒る いかる; read おこり → only 怒る). Readings pick between words; this is what is left
    // for the lookup sheet's list to disambiguate. Empty when no candidate is read that way (a custom
    // reading, or one only the surface's reading data knows): callers then follow the reading's own
    // dictionary entry instead. Every candidate when there is no reading at all.
    static func lookupCandidates(_ candidates: [LookupCandidate], sharingReading reading: String?) -> [LookupCandidate] {
        guard let reading else { return candidates }
        return candidates.filter { $0.surfaceReadings.contains(reading) }
    }

    // The word shown for a form read `displayedReading`: among the words sharing that reading, the
    // user's saved pick if it is one of them, else the only one, else the only common one, else the
    // likeliest; nil only when no word is read that way (see lookupCandidates(_:sharingReading:)). Shared
    // by the lookup sheet and the Read tab's saved-word coloring so a word colors the text the same
    // way it fills the sheet's star.
    static func shownLookupCandidate(
        among candidates: [LookupCandidate],
        chosenEntryID: Int64?,
        displayedReading: String?
    ) -> LookupCandidate? {
        let sharing = lookupCandidates(candidates, sharingReading: displayedReading)
        if let chosen = sharing.first(where: { $0.entry.entryId == chosenEntryID }) {
            return chosen
        }
        if sharing.count == 1 { return sharing[0] }
        return preferredLookupCandidate(among: sharing)
    }
}
