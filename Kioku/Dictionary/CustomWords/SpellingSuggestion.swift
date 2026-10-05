import Foundation

// A dictionary entry the custom-word editor suggests for an unknown spelling, and the spelling to
// store for it (the entry's form with the user's own kanji put back: 駆け寄る suggested for 馳け寄って
// stores 馳け寄る).
nonisolated struct SpellingSuggestion: Sendable {
    let entry: DictionaryEntry
    let spelling: String
}
