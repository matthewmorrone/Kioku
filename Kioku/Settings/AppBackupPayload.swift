import Foundation

// Versioned full-app backup payload covering all persisted Kioku user data.
nonisolated struct AppBackupPayload: Codable {
    static let currentVersion = 4

    var version: Int
    var exportedAt: Date
    var notes: [Note]
    var words: [SavedWord]
    var wordLists: [WordList]
    var history: [HistoryEntry]
    var reviewStats: [AppBackupReviewStats]
    var markedWrong: [Int64]
    // Tri-state learned marks (added in v3). Empty in pre-v3 backups, which decode to [].
    var learned: [Int64]
    var notLearned: [Int64]
    // Mastered marks (added in v4). Empty in pre-v4 backups, which decode to [].
    var mastered: [Int64]
    var lifetimeCorrect: Int
    var lifetimeAgain: Int
    // Audio file bytes, SRT text, and cues for notes that have audio attachments.
    // Empty array when no audio attachments exist.
    var audioAttachments: [AudioAttachmentBackup]
    // The Custom Words list and the defaults already offered. nil in backups made before it
    // existed, which leave the list as it is on restore.
    var customWords: CustomWordStoreState?

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
        learned: [Int64] = [],
        notLearned: [Int64] = [],
        mastered: [Int64] = [],
        lifetimeCorrect: Int,
        lifetimeAgain: Int,
        audioAttachments: [AudioAttachmentBackup] = [],
        customWords: CustomWordStoreState? = nil
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.notes = notes
        self.words = words
        self.wordLists = wordLists
        self.history = history
        self.reviewStats = reviewStats
        self.markedWrong = markedWrong
        self.learned = learned
        self.notLearned = notLearned
        self.mastered = mastered
        self.lifetimeCorrect = lifetimeCorrect
        self.lifetimeAgain = lifetimeAgain
        self.audioAttachments = audioAttachments
        self.customWords = customWords
    }

    private enum CodingKeys: String, CodingKey {
        case version, exportedAt, notes, words, wordLists, history
        case reviewStats, markedWrong, learned, notLearned, mastered, lifetimeCorrect, lifetimeAgain
        case audioAttachments, customWords
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
        learned = (try? c.decode([Int64].self, forKey: .learned)) ?? []
        notLearned = (try? c.decode([Int64].self, forKey: .notLearned)) ?? []
        mastered = (try? c.decode([Int64].self, forKey: .mastered)) ?? []
        lifetimeCorrect = try c.decode(Int.self, forKey: .lifetimeCorrect)
        lifetimeAgain = try c.decode(Int.self, forKey: .lifetimeAgain)
        audioAttachments = (try? c.decode([AudioAttachmentBackup].self, forKey: .audioAttachments)) ?? []
        customWords = try? c.decode(CustomWordStoreState.self, forKey: .customWords)
    }
}
