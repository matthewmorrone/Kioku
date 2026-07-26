import Foundation

// The single canonical "how well does the user know this word?" progression, shared app-wide and
// derived on ReviewStore (see ReviewStore.masteryStage(for:)). New → Learning → Learned → Mastered.
// Learned means every recognition direction (QuestionDirection.tier1: kanji→meaning, kana→meaning,
// kanji→kana) clears the auto-learn bar; Mastered additionally requires every production direction
// (tier2) to clear it too. "Due for review" is a separate orthogonal flag
// (ReviewStore.isDueForReview), not a stage.
enum MasteryStage: Hashable, CaseIterable {
    // Never reviewed and not manually marked either way.
    case new
    // Engaged — reviewed at least once, or explicitly marked "not learned" — but below the bar.
    case learning
    // Every recognition (tier1) direction clears the configured auto-learn bar, or manually
    // marked learned.
    case learned
    // Every direction — recognition AND production (tier1 + tier2) — clears the bar.
    case mastered
}
