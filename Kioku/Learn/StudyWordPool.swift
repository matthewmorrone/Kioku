import Foundation

// One pass of the Learn-tab pool filter: the words a session may draw from, plus how many the
// learned exclusion held back. The count rides along because every caller that wants the pool also
// wants to explain a short one, and deriving it separately means running the whole filter twice on
// every render. Pure stored properties — the rule lives on StudyWordPool.
nonisolated struct StudyWordSelection {
    // Words eligible for a session, after the note, JLPT, scope, and learned filters.
    let words: [SavedWord]
    // How many words cleared the note/JLPT/scope filters but were dropped for being Learned or
    // Mastered. Always 0 when the exclusion is off. Drives the home screens' hint.
    let hiddenLearnedCount: Int
}

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
    // has already learned dropped when `excludeLearned` is on (the default — see
    // LearnedSettings.excludeLearnedKey). Both `.learned` and `.mastered` go: mastered is strictly
    // further along, and `masteryStage` is the app's one definition of that ladder (see ReviewStore).
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
    ) -> StudyWordSelection {
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

    // The scope slice plus the learned exclusion, without the note/JLPT filters. Backs both
    // `matching` and the scope pickers' "(N)" counts, so a count can never advertise cards the
    // session would then refuse to deal.
    //
    // Scope runs first and the exclusion partitions what's left. The two are independent per-word
    // predicates, so the resulting word set is the same either way — but this order makes the
    // held-back count fall out of the partition instead of costing a second pass over the pool.
    // The count is scoped, so it reads as "learned words that are due" under the Due scope rather
    // than "learned words anywhere", which is what the user is being told about.
    static func scoped(
        words: [SavedWord],
        scope: FlashcardScope,
        excludeLearned: Bool,
        stage: (Int64) -> MasteryStage,
        isDue: (Int64) -> Bool,
        isMarkedWrong: (Int64) -> Bool
    ) -> StudyWordSelection {
        let inScope: [SavedWord]
        switch scope {
        case .all:
            inScope = words
        case .dueNow:
            inScope = words.filter { isDue($0.canonicalEntryID) }
        case .markedWrong:
            inScope = words.filter { isMarkedWrong($0.canonicalEntryID) }
        }
        guard excludeLearned else {
            return StudyWordSelection(words: inScope, hiddenLearnedCount: 0)
        }
        let studiable = inScope.filter { isStudiable(stage($0.canonicalEntryID)) }
        return StudyWordSelection(words: studiable, hiddenLearnedCount: inScope.count - studiable.count)
    }

    // The one-line explanation a mode's home screen shows when the learned exclusion is why its
    // selection came up short. Nil when nothing was held back — the shortfall then has some other
    // cause (no saved words, too narrow a note/level/scope filter) and the mode's own message
    // already covers it. Centralized so all three modes word it identically and point at the same
    // escape hatch, which lives in Settings where nothing on their own screen hints at it.
    static func learnedExclusionHint(hiddenLearnedCount: Int) -> String? {
        guard hiddenLearnedCount > 0 else { return nil }
        let noun = hiddenLearnedCount == 1 ? "word" : "words"
        return "\(hiddenLearnedCount) learned \(noun) hidden. Turn off “Skip learned words” in Settings to review them anyway."
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
