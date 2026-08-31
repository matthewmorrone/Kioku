import Foundation

// The dictionary kanji headword and kana reading for a saved word, resolved the same way across
// every quiz/study view (FlashcardCard, MultipleChoiceView, FlashcardTypedAnswerControl,
// FillInBlankView) — previously duplicated once per view. Centralizes only the
// kanjiForms/preferredKana computation, NOT gloss/meaning resolution, which genuinely differs by
// caller (FlashcardCard stacks every selected meaning for its back face; Multiple Choice/Fill in
// the Blank pick a single gloss via fallback precedence) and stays defined at each call site.
// `nonisolated` and synchronous — deliberately does no threading of its own. Every caller runs
// this off the main actor itself (via `Task.detached`, or a `nonisolated` task-group child task —
// see MultipleChoiceView/FillInBlankView's `resolveWordFields`) rather than sharing a cache, so
// display state can't drift from a sibling's cached fetch; this type is the shared logic, not the
// shared execution context.
nonisolated enum WordFormResolver {
    // Computes kanji/kana from an already-fetched `DictionaryEntry` — for callers that also need
    // other data from that same fetch (e.g. `entry.senses`, for gloss resolution) and would
    // otherwise have to query the dictionary a second time just for this.
    static func kanjiAndKana(
        entry: DictionaryEntry,
        store: DictionaryStore,
        entryID: Int64,
        selectedSenseIDs: [Int64],
        selectedGlosses: [GlossRef],
        chosenReading: String? = nil
    ) -> (kanji: String?, kana: String?) {
        // Only ever quiz a kanji form a learner would actually encounter (see
        // DictionaryEntry.firstEverydayKanji) — never the raw headword, which can be tagged
        // rare/outdated/irregular/search-only (rK/oK/iK/sK). When every kanji form is non-everyday
        // this resolves to nil, same as a word with no kanji form at all, rather than falling back
        // to a spelling the learner could never plausibly have seen.
        let kanji = entry.firstEverydayKanji?.text
        // A reading the user pinned with the detail view's switcher is an explicit choice, so it
        // outranks the sense-derived preferred kana — a card studied for 涙/なだ should be quizzed
        // on なだ. Only honored when the entry actually still has that kana form, so a reading left
        // behind by a dictionary rebuild degrades to the computed default instead of a wrong answer.
        if let chosenReading, entry.kanaForms.contains(where: { $0.text == chosenReading }) {
            return (kanji, chosenReading)
        }
        let senseRestrictions = (try? store.fetchSenseRestrictions(entryID: entryID)) ?? []
        let kana = entry.preferredKana(
            selectedSenseIDs: selectedSenseIDs,
            selectedGlosses: selectedGlosses,
            senseRestrictions: senseRestrictions
        )
        return (kanji, kana)
    }

    // Convenience wrapper that also fetches the entry itself, for callers that need nothing else
    // from the dictionary lookup (i.e. don't separately need `entry.senses` etc.).
    static func fetchKanjiAndKana(
        store: DictionaryStore,
        entryID: Int64,
        surface: String,
        selectedSenseIDs: [Int64],
        selectedGlosses: [GlossRef],
        chosenReading: String? = nil
    ) -> (kanji: String?, kana: String?)? {
        guard let data = try? store.fetchWordDisplayData(entryID: entryID, surface: surface) else {
            return nil
        }
        return kanjiAndKana(
            entry: data.entry, store: store, entryID: entryID,
            selectedSenseIDs: selectedSenseIDs, selectedGlosses: selectedGlosses,
            chosenReading: chosenReading
        )
    }
}

// One word's resolved glosses + kanji/kana, keyed by entryID so a caller can correlate it back to
// the originating SavedWord after collecting results from a task group — used by
// `LearnWordPool.resolveWordFields`, which crosses this (not SavedWord or StudyItem) over the
// task-group boundary, since it's a plain Sendable value.
struct ResolvedWordFields: Sendable {
    let entryID: Int64
    // The primary gloss — the one shown as a prompt or as the single expected answer.
    let english: String
    let kanji: String?
    let kana: String?
    // Every gloss of the word's selected senses, `english` first. The accepted-answer set when a
    // typed answer is English, where "to eat" / "eat" are the same answer.
    let glosses: [String]
    // Raw JMdict pos codes across the word's selected senses (e.g. "v1", "vt", "n"). Collapsed to
    // a `WordClass` once it reaches a StudyItem; kept raw here so this stays a plain data carrier.
    let posTags: [String]
}
