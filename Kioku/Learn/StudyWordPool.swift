import Foundation

// Decides which saved words a Learn-tab study session may draw from. Flashcards, Multiple Choice,
// and Fill in the Blank each used to carry their own private copy of this filter, which is how
// "learned" words kept showing up in study sets: the exclusion has to hold in all three (and in the
// counts they display), and three copies of a rule is three places for it to be missing from.
//
// Pure and closure-injected — no store, no MainActor — so the rule is testable on its own and the
// three views keep owning their own state. `nonisolated` for the same reason as AutoLearnPolicy:
// callable from plain (non-`@MainActor`) unit tests.
nonisolated enum StudyWordPool {
    // The words eligible for a session: note filter AND JLPT filter AND scope, with words the user
    // has already learned dropped up front when `excludeLearned` is on (the default — see
    // LearnedSettings.excludeLearnedKey).
    //
    // Learned exclusion is applied BEFORE the scope, not after, so the scope reads as a slice of the
    // studiable pool: "Due" means "due among the words I'm still learning", not "due, minus the ones
    // that then vanish". Both `.learned` and `.mastered` are dropped — mastered is strictly further
    // along, and `masteryStage` is the app's one definition of that ladder (see ReviewStore).
    //
    // Preset sessions (Coverage drilling into a specific level × stage cell, including the Learned
    // cell) deliberately do NOT route through here — they hand their exact word set to the view.
    static func matching(
        words: [SavedWord],
        scope: FlashcardScope,
        noteIDs: Set<UUID>,
        jlptLevels: Set<Int>,
        excludeLearned: Bool,
        jlptLevel: (Int64) -> Int?,
        stage: (Int64) -> MasteryStage,
        isDue: (Int64) -> Bool,
        isMarkedWrong: (Int64) -> Bool
    ) -> [SavedWord] {
        var base = words
        if noteIDs.isEmpty == false {
            base = base.filter { word in
                word.sourceNoteIDs.contains { noteIDs.contains($0) }
            }
        }
        if jlptLevels.isEmpty == false {
            base = base.filter { word in
                guard let level = jlptLevel(word.canonicalEntryID) else { return false }
                return jlptLevels.contains(level)
            }
        }
        return scoped(
            words: base, scope: scope, excludeLearned: excludeLearned,
            stage: stage, isDue: isDue, isMarkedWrong: isMarkedWrong
        )
    }

    // The learned exclusion + scope slice on their own, without the note/JLPT filters. Backs both
    // `matching` and the scope pickers' "(N)" counts, so a count can never advertise cards the
    // session would then refuse to deal.
    static func scoped(
        words: [SavedWord],
        scope: FlashcardScope,
        excludeLearned: Bool,
        stage: (Int64) -> MasteryStage,
        isDue: (Int64) -> Bool,
        isMarkedWrong: (Int64) -> Bool
    ) -> [SavedWord] {
        var base = words
        if excludeLearned {
            base = base.filter { isStudiable(stage($0.canonicalEntryID)) }
        }
        switch scope {
        case .all:
            return base
        case .dueNow:
            return base.filter { isDue($0.canonicalEntryID) }
        case .markedWrong:
            return base.filter { isMarkedWrong($0.canonicalEntryID) }
        }
    }

    // The one-line explanation a mode's home screen shows when the learned exclusion is why its
    // selection came up short. Nil when the exclusion is off or removed nothing — in that case the
    // shortfall has some other cause (no saved words, too narrow a note/level/scope filter) and the
    // mode's own message already covers it. Centralized so all three modes word it identically and
    // point at the same escape hatch, which lives in Settings where nothing on this screen hints at it.
    static func learnedExclusionHint(excludeLearned: Bool, matchedCount: Int, matchedIgnoringLearnedCount: Int) -> String? {
        guard excludeLearned, matchedIgnoringLearnedCount > matchedCount else { return nil }
        let hidden = matchedIgnoringLearnedCount - matchedCount
        let noun = hidden == 1 ? "word" : "words"
        return "\(hidden) learned \(noun) hidden. Turn off “Skip learned words” in Settings to review them anyway."
    }

    // Whether a word at this stage still belongs in a study set. New and Learning do; Learned and
    // Mastered are what the user has told us (or the auto-learn policy has concluded) they're done
    // with, which is exactly what "exclude learned" means.
    static func isStudiable(_ stage: MasteryStage) -> Bool {
        switch stage {
        case .new, .learning: return true
        case .learned, .mastered: return false
        }
    }
}
