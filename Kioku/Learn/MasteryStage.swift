import Foundation

// The single canonical "how well does the user know this word?" progression, shared app-wide and
// derived on ReviewStore (see ReviewStore.masteryStage(for:)). New → Learning → Learned. "Due for
// review" is a separate orthogonal flag (ReviewStore.isDueForReview), NOT a fourth stage.
enum MasteryStage: Hashable, CaseIterable {
    // Never reviewed and not manually marked either way.
    case new
    // Engaged — reviewed at least once, or explicitly marked "not learned" — but below the bar.
    case learning
    // Cleared the configured auto-learn bar, or manually marked learned.
    case learned
}
