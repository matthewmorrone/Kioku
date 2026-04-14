import Foundation

// Versioned full-app backup payload covering all persisted Kioku user data.
nonisolated struct AppBackupPayload: Codable {
    static let currentVersion = 2

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
    // Audio file bytes, SRT text, and cues for notes that have audio attachments.
    // Empty array when no audio attachments exist.
    var audioAttachments: [AudioAttachmentBackup]

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
        lifetimeAgain: Int,
        audioAttachments: [AudioAttachmentBackup] = []
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
        self.audioAttachments = audioAttachments
    }

    private enum CodingKeys: String, CodingKey {
        case version, exportedAt, notes, words, wordLists, history
        case reviewStats, markedWrong, lifetimeCorrect, lifetimeAgain
        case audioAttachments
    }

    // Custom decoder so version-1 backups (no audioAttachments key) decode cleanly.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        exportedAt = try c.decode(Date.self, forKey: .exportedAt)
        notes = try c.decode([Note].self, forKey: .notes)
        words = try c.decode([SavedWord].self, forKey: .words)
        wordLists = try c.decode([WordList].self, forKey: .wordLists)
        history = try c.decode([HistoryEntry].self, forKey: .history)
        reviewStats = try c.decode([AppBackupReviewStats].self, forKey: .reviewStats)
        markedWrong = try c.decode([Int64].self, forKey: .markedWrong)
        lifetimeCorrect = try c.decode(Int.self, forKey: .lifetimeCorrect)
        lifetimeAgain = try c.decode(Int.self, forKey: .lifetimeAgain)
        audioAttachments = (try? c.decode([AudioAttachmentBackup].self, forKey: .audioAttachments)) ?? []
    }
}
