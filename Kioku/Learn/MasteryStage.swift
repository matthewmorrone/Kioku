import Foundation

// The single canonical "how well does the user know this word?" progression, shared app-wide and
// derived on WordsStore (see WordsStore.masteryStage(for:)). New → Learning → Learned → Mastered.
// Learned means every recognition direction (QuestionDirection.tier1: kanji→meaning, kana→meaning,
// kanji→kana) has been answered right at least once; Mastered additionally requires every production
// direction (tier2). "Due for review" is a separate orthogonal flag
// (WordsStore.isDueForReview), not a stage. `nonisolated` (like AutoLearnPolicy) so pure rule code
// off the main actor can name these cases — StudyWordPool's learned exclusion is written against
// this ladder and is unit-tested outside any actor.
nonisolated enum MasteryStage: Hashable, CaseIterable {
    // Carries neither the Learned nor the Not Learned flag.
    case new
    // Explicitly flagged Not Learned.
    case learning
    // Flagged Learned, whether by hand or by auto-learn once every recognition (tier1) direction
    // has been answered right at least once.
    case learned
    // Flagged Learned and every direction — recognition AND production (tier1 + tier2) —
    // answered right at least once.
    case mastered
}
