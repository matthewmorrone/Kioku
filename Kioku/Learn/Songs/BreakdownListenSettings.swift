import Foundation

// UserDefaults keys + defaults for the Breakdown's listen-along options menu. Bound by
// @AppStorage in SongStepperView; centralized so the keys and their defaults can't drift
// between the menu that writes them and the script/controller setup that reads them. The
// particle, katakana and vocalization filters are shared: the lyrics card's word bubbles read
// the same keys (LyricsView), so a kind of word hidden in one is hidden in the other.
nonisolated enum BreakdownListenSettings {
    // Stop at the end of every line instead of running on into the next one.
    static let pauseAfterLineKey = "breakdown.listen.pauseAfterLine"
    // How many times each word is heard (sung snippet, or synthesized when there is none)
    // before its definition.
    static let wordRepeatCountKey = "breakdown.listen.wordRepeatCount"
    // Whether a word already covered earlier in the song is shown and spoken again on later
    // lines (SongCoveredWords); applies to the cards as well as listen-along.
    static let repeatEarlierWordsKey = "breakdown.repeatEarlierWords"
    // Which kinds of word (and, for vocalizations, whole lines) are shown and spoken — see
    // SongWordVisibility. The breakdown always carries them; these only hide. The first three
    // also decide which words get a bubble on the lyrics card.
    static let showParticlesKey = "breakdown.showParticles"
    static let showKatakanaKey = "breakdown.showKatakana"
    static let showVocalizationsKey = "breakdown.showVocalizations"
    static let showPatternsKey = "breakdown.showPatterns"

    // Whether listen-along iterates through each line's split view (BreakdownWordWalk raw value).
    static let wordWalkKey = "breakdown.listen.wordWalk"

    static let defaultWordWalk = BreakdownWordWalk.yes

    // The word-walk choice as stored right now. The controller asks this on every word step from a
    // closure that outlives the view value that made it, so it reads UserDefaults itself rather
    // than a captured @AppStorage copy, which can hold the value from when the closure was built.
    static func currentWordWalk() -> BreakdownWordWalk {
        guard let raw = UserDefaults.standard.string(forKey: wordWalkKey),
              let choice = BreakdownWordWalk(rawValue: raw) else { return defaultWordWalk }
        return choice
    }
    static let defaultPauseAfterLine = false
    static let defaultWordRepeatCount = 1
    static let defaultRepeatEarlierWords = true
    static let defaultShowParticles = false
    static let defaultShowKatakana = true
    static let defaultShowVocalizations = false
    static let defaultShowPatterns = true
    static let wordRepeatChoices = [1, 2, 3]
}
