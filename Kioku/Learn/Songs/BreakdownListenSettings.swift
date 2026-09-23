import Foundation

// UserDefaults keys + defaults for the Breakdown's listen-along options menu. Bound by
// @AppStorage in SongStepperView; centralized so the keys and their defaults can't drift
// between the menu that writes them and the script/controller setup that reads them.
nonisolated enum BreakdownListenSettings {
    // Stop at the end of every line instead of running on into the next one.
    static let pauseAfterLineKey = "breakdown.listen.pauseAfterLine"
    // How many times each word is heard (sung snippet, or synthesized when there is none)
    // before its definition.
    static let wordRepeatCountKey = "breakdown.listen.wordRepeatCount"

    static let defaultPauseAfterLine = false
    static let defaultWordRepeatCount = 1
    static let wordRepeatChoices = [1, 2, 3]
}
