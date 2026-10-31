import Foundation

// Which of a breakdown's words, lines and pattern notes are shown and spoken, from the Breakdown
// options menu (BreakdownListenSettings). The breakdown itself always carries everything — particles,
// katakana words, vocalizations — so flipping an option is instant and never needs a
// regenerate. One rule, used by both SongLineCard (through SongStepperView) and
// SongListenScript, so what is shown and what is spoken can't disagree.
//
// Always excluded, whatever the options: a bullet with an empty surface, and a bullet whose
// surface is English rather than Japanese (a mixed-language line's English portion given its
// own bullet). The English check is a script test — ScriptClassifier.containsJapanese looks
// for actual kana/kanji scalars — so a genuine Japanese word is never misclassified by it.
nonisolated struct SongWordVisibility: Equatable, Sendable {
    var showsParticles: Bool
    var showsKatakana: Bool
    var showsVocalizations: Bool
    // Whether each line's "Pattern to Bank" note is shown and spoken.
    var showsPatterns: Bool

    // The bracketed tag the prompt puts on a vocalization's word bullet (`[vocalization]`,
    // parsed into SongWord.grammarTag) and at the start of a vocalization line's gist.
    static let vocalizationTag = "vocalization"
    // The bracketed tag the prompt puts on a particle's word bullet (`[particle]`) — judged
    // in context by the model, so compounds like よね count and content-word こと doesn't.
    static let particleTag = "particle"

    // The options menu's out-of-the-box choices (BreakdownListenSettings defaults).
    static let defaults = SongWordVisibility(
        showsParticles: BreakdownListenSettings.defaultShowParticles,
        showsKatakana: BreakdownListenSettings.defaultShowKatakana,
        showsVocalizations: BreakdownListenSettings.defaultShowVocalizations,
        showsPatterns: BreakdownListenSettings.defaultShowPatterns
    )

    // Whether `word` is shown and spoken. A particle is a bullet tagged `[particle]`, or — for
    // breakdowns generated before the tag — a surface in the canonical single-kana
    // KanaData.particleSet the Read-tab vocab extractor uses. Katakana means the whole surface
    // is katakana (loanwords, and native words written in katakana for effect).
    func shows(_ word: SongWord) -> Bool {
        let surface = word.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard surface.isEmpty == false else { return false }
        guard ScriptClassifier.containsJapanese(surface) else { return false }
        let tag = word.grammarTag?.lowercased()
        let isListedNonParticle = KanaData.nonParticleWords.contains(surface)
        if showsParticles == false, isListedNonParticle == false,
           tag == Self.particleTag || KanaData.particleSet.contains(surface) {
            return false
        }
        if showsKatakana == false, ScriptClassifier.isPureKatakana(surface) { return false }
        if showsVocalizations == false, tag == Self.vocalizationTag { return false }
        return true
    }

    // Whether a whole line is shown and spoken: false only for a vocalization line while
    // vocalizations are hidden. A "= line N" / "Parallel to line N" repeat follows its target.
    func showsLine(_ line: SongLine, linesByIndex: [Int: SongLine]) -> Bool {
        guard showsVocalizations == false else { return true }
        if line.isVocalization == true { return false }
        if let reference = line.reference,
           linesByIndex[reference.targetLineIndex]?.isVocalization == true {
            return false
        }
        return true
    }
}
