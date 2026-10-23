import Foundation

// The version-5 additions to a full-app backup: derived and UserDefaults-backed data that
// version 4 left behind. Absent from older backups, which leave these areas as they are on restore.
nonisolated struct AppBackupExtras: Codable {
    // Song breakdowns, one per note (they cost LLM calls to regenerate).
    var breakdowns: [SongBreakdown]
    // The free-form guidance typed with each song's breakdown request, keyed by note UUID string.
    var breakdownUserNotes: [String: String]
    var savedKanji: [SavedKanji]
    var singHistory: [SingSessionRecord]
    // The raw comma-joined demotions list; nil when the user never customised it.
    var segmentationDemotions: String?
    // Lyrics translations keyed by attachment UUID string, then by cue text.
    var lyricsTranslations: [String: [String: String]]
    var guessedGlosses: [String: String]
    var compositeGlosses: [String: String]
    // Allow-listed preferences (see AppBackupCollector.settingKeys); device-local state is not here.
    var settings: [String: AppBackupSettingValue]
    // API keys by Keychain account; nil unless the export chose to include them.
    var apiKeys: [String: String]?
    // File names under stems/ in a zip backup (isolated vocal stems and instrumentals).
    var stemFiles: [String]
}
