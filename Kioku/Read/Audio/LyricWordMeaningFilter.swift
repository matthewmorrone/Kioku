import Foundation

// Which lyric words get a meaning shown, for the lyrics card's word bubbles and the full-screen
// word view alike. Particles, katakana words and vocalizations follow the filters shared with the
// Breakdown (BreakdownListenSettings, through SongWordVisibility); English Words is the lyrics
// card's own option. Never for punctuation or words written in Latin letters — only Japanese
// script counts. The dictionary-side checks (is it a particle, a loanword) come from the Read
// view, which owns the dictionary, so no lexical lookup happens here.
struct LyricWordMeaningFilter {
    var showsParticles: Bool
    var showsKatakana: Bool
    var showsVocalizations: Bool
    var showsLoanwords: Bool
    // Whether the dictionary counts a word as a particle, given its note location and surface.
    var isParticle: ((Int, String) -> Bool)?
    // Whether a word is a katakana loanword.
    var isLoanword: ((String) -> Bool)?

    // Whether a breakdown word gets its meaning: by its spelling, then by the breakdown's own tags
    // (particle, vocalization) through the same rule the Breakdown's cards use.
    // A particle whose bubble meaning is a single word ("with", "from", "too") stays while
    // particles are hidden: the word carries real meaning, unlike は "topic marker" or を "direct
    // object", which only name a grammar role. `gloss` is the bubble's meaning, when known.
    func allows(breakdownWord word: SongWord, gloss: String? = nil) -> Bool {
        let surface = word.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibility = SongWordVisibility(
            showsParticles: showsParticles || Self.isSingleWord(gloss),
            showsKatakana: showsKatakana,
            showsVocalizations: showsVocalizations,
            showsPatterns: false
        )
        return allows(surface: surface) && visibility.shows(word)
    }

    // Whether a word the breakdown doesn't cover gets its dictionary meaning: by its spelling,
    // and not a particle while particles are hidden.
    // A particle with a single-word meaning stays (see allows(breakdownWord:gloss:)).
    func allows(dictionaryWord surface: String, at location: Int, gloss: String? = nil) -> Bool {
        allows(surface: surface) && (showsParticles || Self.isSingleWord(gloss) || isParticle?(location, surface) != true)
    }

    // Whether a bubble meaning is one word: no spaces, so "with" and "too" count, "to" followed by a
    // verb, "topic marker" and "(indicates) object" do not.
    static func isSingleWord(_ gloss: String?) -> Bool {
        guard let gloss else { return false }
        let trimmed = gloss.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty == false && trimmed.contains(where: \.isWhitespace) == false
    }

    // The spelling checks both kinds of word share.
    private func allows(surface: String) -> Bool {
        guard surface.contains(where: \.isLetter), ScriptClassifier.containsJapanese(surface) else { return false }
        if showsKatakana == false, ScriptClassifier.isKatakanaWord(surface) { return false }
        if showsLoanwords == false, isLoanword?(surface) == true { return false }
        return true
    }
}
