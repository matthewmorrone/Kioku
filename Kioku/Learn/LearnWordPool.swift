import Foundation

// A saved word resolved to its display string on every field, used to build questions and to
// supply distractors. Resolved once at session start so per-question assembly stays synchronous.
// Shared by every Learn activity (it began life as Multiple Choice's own type, which Fill in the
// Blank then borrowed across module boundaries).
struct StudyItem: Identifiable {
    let word: SavedWord
    // Saved/encountered surface, kept only as the fallback when the dictionary supplies no form
    // for a field — never studied as a form in its own right, since it may be inflected.
    let surface: String
    let kanji: String?       // dictionary kanji headword (漢字), nil when not distinct from surface
    let kana: String?        // kana reading (かな), nil when not distinct from surface
    let english: String      // primary gloss, used as the prompt or the expected answer
    // Every gloss of the word's selected senses, so a typed English answer can be graded against
    // the whole set rather than just `english` (see `AnswerScorer.grade(input:anyOf:)`).
    let glosses: [String]
    // Whether the word has a kanji form at all — distinct from `kanji != nil`, which is also nil
    // when the headword merely equals the surface.
    let hasKanjiForm: Bool
    // What kind of word this is, so Multiple Choice can offer distractors of the same kind rather
    // than making the answer the only verb among nouns.
    let wordClass: WordClass

    var id: Int64 { word.canonicalEntryID }

    // The display string for one quizzable field, falling back to the surface when the dictionary
    // has no distinct form so every item can still stand in as a distractor for any field.
    func value(for field: StudyField) -> String {
        switch field {
        case .kanji: return kanji ?? surface
        case .kana: return kana ?? surface
        case .meaning: return english
        }
    }
}

// Builds the word pool every Learn activity draws from: filtering by the user's selection, then by
// which directions each word can actually be asked. Previously duplicated across Flashcards,
// Multiple Choice, and Fill in the Blank, where the three copies had already drifted.
@MainActor
enum LearnWordPool {
    // The words a session may draw from. The note / JLPT / scope / learned-exclusion rule lives in
    // `StudyWordPool` (pure, closure-injected, independently tested); this adds the one filter that
    // is this layer's own — a word must be askable in at least one of the ticked directions, which
    // needs the kanji-form estimate below and so can't live in that pure rule.
    //
    // `hiddenLearnedCount` rides through untouched: it explains a pool shortened by the learned
    // exclusion, and a word dropped for having no askable direction isn't that.
    static func eligible(
        in words: [SavedWord],
        options: LearnActivityOptions,
        excludeLearned: Bool,
        wordsStore: WordsStore,
        dictionaryStore: DictionaryStore?
    ) -> StudyWordSelection {
        let selection = StudyWordPool.matching(
            words: words,
            scope: options.scope,
            noteIDs: options.selectedNoteIDs,
            jlptLevels: options.selectedJLPTLevels,
            excludeLearned: excludeLearned,
            jlptLevel: { dictionaryStore?.jlptLevel(for: $0) },
            stage: { wordsStore.masteryStage(for: $0) },
            isDue: { wordsStore.isDue(id: $0) },
            isMarkedWrong: { wordsStore.markedWrong.contains($0) }
        )
        let askable = selection.words.filter { word in
            options.directions
                .askable(hasKanjiForm: estimatedHasKanjiForm(word, wordsStore: wordsStore))
                .isEmpty == false
        }
        return StudyWordSelection(words: askable, hiddenLearnedCount: selection.hiddenLearnedCount)
    }

    // Best cheap answer to "does this word have a kanji form?" — the fact recorded by a previous
    // review when there is one, otherwise whether the saved surface shows any kanji. Used only for
    // pool counting, never for promotion: a wrong guess here changes a number on screen, whereas
    // the promotion bars insist on a resolved headword before relaxing (see ReviewWordStats).
    static func estimatedHasKanjiForm(_ word: SavedWord, wordsStore: WordsStore) -> Bool {
        wordsStore.hasKanjiForm(for: word.canonicalEntryID)
            ?? ScriptClassifier.containsKanji(word.surface)
    }

    // Resolves each saved word to its kanji, kana, and gloss set. Each word's lookup runs as its
    // own child task in a task group instead of one-at-a-time, so a large word list resolves in
    // roughly the time of the slowest single lookup rather than the sum of all of them. Only
    // Sendable primitives (not SavedWord/StudyItem) cross into `resolveWordFields`, and results are
    // correlated back to their word via entryID afterward — this project's default actor isolation
    // would otherwise make the lookup implicitly @MainActor, silently serializing every
    // "concurrent" lookup back onto the main thread. Drops any word whose lookup fails or yields no
    // gloss, since it could not supply a prompt or an answer.
    static func resolveItems(for words: [SavedWord], dictionaryStore: DictionaryStore?) async -> [StudyItem] {
        guard let store = dictionaryStore else { return [] }
        var wordsByID: [Int64: SavedWord] = [:]
        for word in words { wordsByID[word.canonicalEntryID] = word }

        let resolved = await withTaskGroup(of: ResolvedWordFields?.self) { group in
            for word in words {
                let entryID = word.canonicalEntryID
                let surface = word.surface
                let selectedSenseIDs = word.selectedSenseIDs
                let selectedGlosses = word.selectedGlosses
                let chosenReading = word.selectedReading
                group.addTask {
                    await resolveWordFields(
                        store: store, entryID: entryID, surface: surface,
                        selectedSenseIDs: selectedSenseIDs, selectedGlosses: selectedGlosses,
                        chosenReading: chosenReading
                    )
                }
            }
            var results: [ResolvedWordFields] = []
            for await item in group {
                if let item { results.append(item) }
            }
            return results
        }

        var items: [StudyItem] = []
        for fields in resolved {
            guard let word = wordsByID[fields.entryID] else { continue }
            let surface = word.surface
            let gloss = fields.english.trimmingCharacters(in: .whitespacesAndNewlines)
            guard gloss.isEmpty == false else { continue }
            // Keep kanji/kana only when distinct and non-empty; otherwise nil so the field falls
            // back to the surface.
            let kanji = fields.kanji?.trimmingCharacters(in: .whitespacesAndNewlines)
            let kana = fields.kana?.trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(StudyItem(
                word: word,
                surface: surface,
                kanji: (kanji?.isEmpty == false && kanji != surface) ? kanji : nil,
                kana: (kana?.isEmpty == false && kana != surface) ? kana : nil,
                english: gloss,
                glosses: fields.glosses.isEmpty ? [gloss] : fields.glosses,
                // Kanji visible in the surface counts even if the dictionary reported no headword,
                // so this can never wrongly claim a kanji-bearing word is kana-only.
                hasKanjiForm: kanji?.isEmpty == false || ScriptClassifier.containsKanji(surface),
                wordClass: WordClass.from(posTags: fields.posTags)
            ))
        }
        return items
    }

    // Resolves one word's kanji/kana/gloss set from the dictionary. `nonisolated`, and takes only
    // Sendable primitives rather than SavedWord directly — see `resolveItems` for why that matters.
    private nonisolated static func resolveWordFields(
        store: DictionaryStore,
        entryID: Int64,
        surface: String,
        selectedSenseIDs: [Int64],
        selectedGlosses: [GlossRef],
        chosenReading: String?
    ) async -> ResolvedWordFields? {
        guard let data = try? store.fetchWordDisplayData(entryID: entryID, surface: surface) else {
            return nil
        }
        var sensesByID: [Int64: DictionaryEntrySense] = [:]
        for sense in data.entry.senses { sensesByID[sense.senseID] = sense }

        // Every gloss the user actually selected, in selection order — the accepted-answer set for
        // a typed English answer. Falls back to the entry's first sense when nothing was selected,
        // matching how the single primary gloss was already chosen.
        var glosses: [String] = []
        for senseID in selectedSenseIDs {
            if let sense = sensesByID[senseID] { glosses.append(contentsOf: sense.glosses) }
        }
        for ref in selectedGlosses {
            if let sense = sensesByID[ref.senseID], ref.glossIndex >= 0, ref.glossIndex < sense.glosses.count {
                glosses.append(sense.glosses[ref.glossIndex])
            }
        }
        if glosses.isEmpty { glosses = data.entry.senses.first?.glosses ?? [] }
        guard let primary = glosses.first else { return nil }

        // Pos codes from the senses the user actually selected, falling back to the whole entry
        // when nothing was selected — the same rule the gloss set above follows, so a word saved
        // for its noun sense isn't classed by a verb sense it was never studied for.
        let posSenses = selectedSenseIDs.compactMap { sensesByID[$0] }
        let classedSenses = posSenses.isEmpty ? data.entry.senses : posSenses
        var posTags: [String] = []
        for sense in classedSenses {
            guard let pos = sense.pos else { continue }
            for tag in pos.components(separatedBy: ",") {
                let trimmed = tag.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty == false { posTags.append(trimmed) }
            }
        }

        let forms = WordFormResolver.kanjiAndKana(
            entry: data.entry, store: store, entryID: entryID,
            selectedSenseIDs: selectedSenseIDs, selectedGlosses: selectedGlosses,
            chosenReading: chosenReading
        )
        return ResolvedWordFields(
            entryID: entryID, english: primary, kanji: forms.kanji, kana: forms.kana,
            glosses: glosses, posTags: posTags
        )
    }
}
