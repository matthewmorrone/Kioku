import Foundation

// A spelling the user taught the app from the lookup sheet: another spelling of a dictionary word
// (ウエファース for ウエハース, 馳け寄る for 駆け寄る) or a word of its own. Kept by LearnedWordStore,
// included in backups, and written into the downloaded dictionary by LearnedWordApplier so the
// segmenter, furigana and lookups treat it like any dictionary word.
nonisolated struct LearnedWord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var spelling: String
    var kind: LearnedWordKind
    var createdAt: Date
}

// What a learned spelling stands for: an existing entry, by its stable JMdict ent_seq (row ids
// change with every dictionary build), or a new word with the reading and meaning the user typed.
nonisolated enum LearnedWordKind: Codable, Equatable, Sendable {
    case spellingOf(entSeq: Int64)
    case newWord(reading: String, meaning: String)
}
