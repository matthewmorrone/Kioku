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
    func allows(breakdownWord word: SongWord) -> Bool {
        let surface = word.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibility = SongWordVisibility(
            showsParticles: showsParticles,
            showsKatakana: showsKatakana,
            showsVocalizations: showsVocalizations,
            showsPatterns: false
        )
        return allows(surface: surface) && visibility.shows(word)
    }

    // Whether a word the breakdown doesn't cover gets its dictionary meaning: by its spelling,
    // and not a particle while particles are hidden.
    func allows(dictionaryWord surface: String, at location: Int) -> Bool {
        allows(surface: surface) && (showsParticles || isParticle?(location, surface) != true)
    }

    // The spelling checks both kinds of word share.
    private func allows(surface: String) -> Bool {
        guard surface.contains(where: \.isLetter), ScriptClassifier.containsJapanese(surface) else { return false }
        if showsKatakana == false, ScriptClassifier.isKatakanaWord(surface) { return false }
        if showsLoanwords == false, isLoanword?(surface) == true { return false }
        return true
    }
}
