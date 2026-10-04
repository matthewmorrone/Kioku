import Foundation

// One word in the user's Custom Words list: the dictionary's extras.json entries (seeded as
// defaults the first time a dictionary carrying them is seen), plus anything added from the lookup
// sheet's Learn Spelling or the Custom Words editor. Mirrors an extras.json entry so the list
// exports and imports as one (CustomWordsExtrasCodec). Written into the downloaded dictionary by
// CustomWordApplier, in place of the copies the build baked in.
nonisolated struct CustomWord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    // The stable JMdict-style sequence number the word is written under, so saved words keep
    // pointing at it across re-applies: a default keeps its build-time ent_seq, a new word gets one
    // when first stored (CustomWordStore). nil for a spelling of another entry.
    var entSeq: Int64?
    // When set, kanji and kana are extra spellings of this existing entry and senses are unused.
    var sameAsEntSeq: Int64?
    var kanji: [String]
    var kana: [String]
    var senses: [CustomWordSense]
    // The headword of the default this was seeded from, nil for the user's own words. Lets a new
    // dictionary's defaults be told apart from ones already offered (and maybe deleted).
    var defaultKey: String?
}

// One sense of a custom word, as extras.json writes it: part-of-speech and misc codes (n, exp,
// poet …) and English glosses.
nonisolated struct CustomWordSense: Codable, Equatable, Sendable {
    var partOfSpeech: [String]
    var misc: [String]
    var glosses: [String]
}

// Everything CustomWordStore persists: the list, and the defaults already offered (by headword,
// with the original of each so Restore Defaults can bring a deleted or edited one back).
nonisolated struct CustomWordStoreState: Codable, Equatable, Sendable {
    var words: [CustomWord]
    var offeredDefaults: [String: CustomWord]
}
