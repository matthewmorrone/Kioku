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
    // Words passing the note / JLPT / scope filters AND askable in at least one ticked direction.
    // The direction test uses `estimatedHasKanjiForm`, so this is exact for words already reviewed
    // with dictionary data and a good estimate otherwise; `resolveItems` re-checks against the real
    // headword when the session is built, which is why the built question count can come in under
    // the pool count.
    static func eligibleWords(
        in words: [SavedWord],
        options: LearnActivityOptions,
        reviewStore: ReviewStore,
        dictionaryStore: DictionaryStore?
    ) -> [SavedWord] {
        filtered(words, options: options, reviewStore: reviewStore, dictionaryStore: dictionaryStore)
            .filter { word in
                options.directions
                    .askable(hasKanjiForm: estimatedHasKanjiForm(word, reviewStore: reviewStore))
                    .isEmpty == false
            }
    }

    // The note / JLPT / scope filters alone, without the direction test — what the scope picker's
    // own counts are built from, since those describe the collection, not the configured session.
    static func filtered(
        _ words: [SavedWord],
        options: LearnActivityOptions,
        reviewStore: ReviewStore,
        dictionaryStore: DictionaryStore?
    ) -> [SavedWord] {
        var base = words
        if options.selectedNoteIDs.isEmpty == false {
            base = base.filter { word in
                word.sourceNoteIDs.contains(where: { options.selectedNoteIDs.contains($0) })
            }
        }
        if options.selectedJLPTLevels.isEmpty == false {
            base = base.filter { word in
                guard let level = dictionaryStore?.jlptLevel(for: word.canonicalEntryID) else { return false }
                return options.selectedJLPTLevels.contains(level)
            }
        }
        return scoped(base, scope: options.scope, reviewStore: reviewStore)
    }

    // Narrows to one scope slice. Split out so the scope picker can label each option with its own
    // count without re-running the note/JLPT filters three times.
    static func scoped(_ words: [SavedWord], scope: FlashcardScope, reviewStore: ReviewStore) -> [SavedWord] {
        switch scope {
        case .all: return words
        case .dueNow: return words.filter { reviewStore.isDue(id: $0.canonicalEntryID) }
        case .markedWrong: return words.filter { reviewStore.markedWrong.contains($0.canonicalEntryID) }
        }
    }

    // Best cheap answer to "does this word have a kanji form?" — the fact recorded by a previous
    // review when there is one, otherwise whether the saved surface shows any kanji. Used only for
    // pool counting, never for promotion: a wrong guess here changes a number on screen, whereas
    // the promotion bars insist on a resolved headword before relaxing (see ReviewWordStats).
    static func estimatedHasKanjiForm(_ word: SavedWord, reviewStore: ReviewStore) -> Bool {
        reviewStore.hasKanjiForm(for: word.canonicalEntryID)
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
                group.addTask {
                    await resolveWordFields(
                        store: store, entryID: entryID, surface: surface,
                        selectedSenseIDs: selectedSenseIDs, selectedGlosses: selectedGlosses
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
                hasKanjiForm: kanji?.isEmpty == false || ScriptClassifier.containsKanji(surface)
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
        selectedGlosses: [GlossRef]
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

        let forms = WordFormResolver.kanjiAndKana(
            entry: data.entry, store: store, entryID: entryID,
            selectedSenseIDs: selectedSenseIDs, selectedGlosses: selectedGlosses
        )
        return ResolvedWordFields(
            entryID: entryID, english: primary, kanji: forms.kanji, kana: forms.kana, glosses: glosses
        )
    }
}
