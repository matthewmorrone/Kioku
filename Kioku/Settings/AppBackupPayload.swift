import Foundation

// Versioned full-app backup payload covering all persisted Kioku user data.
struct AppBackupPayload: Codable {
    static let currentVersion = 1

    var version: Int
    var exportedAt: Date
    var notes: [Note]
    var words: [SavedWord]
    var wordLists: [WordList]
    var history: [HistoryEntry]
    var reviewStats: [AppBackupReviewStats]
    var markedWrong: [Int64]
    var lifetimeCorrect: Int
    var lifetimeAgain: Int

    // Creates a full backup payload from the current in-memory stores.
    init(
        version: Int = currentVersion,
        exportedAt: Date = Date(),
        notes: [Note],
        words: [SavedWord],
        wordLists: [WordList],
        history: [HistoryEntry],
        reviewStats: [AppBackupReviewStats],
        markedWrong: [Int64],
        lifetimeCorrect: Int,
        lifetimeAgain: Int
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.notes = notes
        self.words = words
        self.wordLists = wordLists
        self.history = history
        self.reviewStats = reviewStats
        self.markedWrong = markedWrong
        self.lifetimeCorrect = lifetimeCorrect
        self.lifetimeAgain = lifetimeAgain
    }
}
