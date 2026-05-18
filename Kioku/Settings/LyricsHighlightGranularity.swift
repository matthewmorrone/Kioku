import Foundation

// Controls how the in-cue highlight advances during lyric playback.
// When no karaoke checkpoint data is attached to the active cue, the renderer silently falls back
// to whole-cue (sentence) behavior regardless of this setting.
enum LyricsHighlightGranularity: String, CaseIterable {
    case sentence
    case word
    case mora

    // Display name shown in Settings.
    var displayName: String {
        switch self {
        case .sentence: return "Sentence"
        case .word:     return "Word"
        case .mora:     return "Mora"
        }
    }

    static let storageKey = "kioku.settings.lyricsHighlightGranularity"
    static let defaultValue = LyricsHighlightGranularity.word
}
