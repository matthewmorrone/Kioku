import Foundation

// The single canonical "how well does the user know this word?" progression, shared app-wide and
// derived on ReviewStore (see ReviewStore.masteryStage(for:)). New → Learning → Learned → Mastered.
// Learned means every recognition direction (QuestionDirection.tier1: kanji→meaning, kana→meaning,
// kanji→kana) has been answered right at least once; Mastered additionally requires every production
// direction (tier2). "Due for review" is a separate orthogonal flag
// (ReviewStore.isDueForReview), not a stage. `nonisolated` (like AutoLearnPolicy) so pure rule code
// off the main actor can name these cases — StudyWordPool's learned exclusion is written against
// this ladder and is unit-tested outside any actor.
nonisolated enum MasteryStage: Hashable, CaseIterable {
    // Never reviewed and not manually marked either way.
    case new
    // Engaged — reviewed at least once, or explicitly marked "not learned" — but below the bar.
    case learning
    // Every recognition (tier1) direction answered right at least once, or manually
    // marked learned.
    case learned
    // Every direction — recognition AND production (tier1 + tier2) — answered right at least once.
    case mastered
}
