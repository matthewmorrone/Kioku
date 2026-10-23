import Foundation
import LyricAlignment

// Gathers the version-5 backup data from the stores that keep it (breakdown files, saved kanji,
// sing history, UserDefaults caches and preferences, the Keychain) and writes a restored
// snapshot back. Kept apart from the Settings view so the lists of what travels live in one place.
@MainActor
enum AppBackupExtrasStore {
    private static let translationKeyPrefix = "kioku.lyricsTranslationsByText."
    private static let breakdownNoteKeyPrefix = "songBreakdown.userNote."

    // Preferences that travel. Exact keys and prefixes are listed so device-local state
    // (debug toggles, last-open note, pasteboard counters, tab position) never rides along.
    private static let settingPrefixes = [
        "kioku.settings.", "kioku.customTheme.", "tokenColors.", "breakdown.", "kioku.sing.",
        "learn.", "kioku.tour.seen."
    ]
    private static let settingKeys: Set<String> = [
        "kioku.japaneseTheme", "kioku.themeID", "kioku.llm.provider", "kioku.llm.useLLM",
        "kioku.autoLearn.enabled", "kioku.study.excludeLearned", "clozeExcludeDuplicateLines",
        "clipboardLookup.autoDetectEnabled", "kioku.segmenter.strategy", "searchShowKanji",
        "savedWordsShowKanji", "savedWordsSortOrder", "historySortOrder", "browseProficiency.level",
        "notes.sortField", "notes.sortAscending", "notes.seededSampleNotes",
        "wordOfTheDay.hour", "wordOfTheDay.minute"
    ]
    // `kioku.sing.history` is the sing store's own data, carried separately as `singHistory`.
    // `learn.pageIndex` is tab position, which stays with the device.
    private static let excludedSettingKeys: Set<String> = ["kioku.sing.history", "learn.pageIndex"]

    // Keychain accounts that can travel, by the name used in the backup file.
    private static let apiKeyAccounts = ["openai", "claude", "jimaku"]

    // Whether a UserDefaults key is one a backup may carry or overwrite.
    static func isBackedUpSetting(_ key: String) -> Bool {
        guard excludedSettingKeys.contains(key) == false else { return false }
        return settingKeys.contains(key) || settingPrefixes.contains { key.hasPrefix($0) }
    }

    // Snapshots everything version 5 adds. API keys are read only when the export asked for them,
    // and stem file names only when stems are included (the files themselves go into the zip).
    static func collect(
        notes: [Note],
        options: AppBackupExportOptions,
        breakdownStore: SongBreakdownStore,
        savedKanjiStore: SavedKanjiStore
    ) -> AppBackupExtras {
        let defaults = UserDefaults.standard
        var userNotes: [String: String] = [:]
        for note in notes {
            let text = SongBreakdownUserNote.note(forNoteID: note.id)
            if text.isEmpty == false { userNotes[note.id.uuidString] = text }
        }

        var translations: [String: [String: String]] = [:]
        for attachmentID in notes.compactMap(\.audioAttachmentID) {
            let stored = defaults.dictionary(forKey: translationKeyPrefix + attachmentID.uuidString) as? [String: String]
            if let stored, stored.isEmpty == false { translations[attachmentID.uuidString] = stored }
        }

        var settings: [String: AppBackupSettingValue] = [:]
        for (key, object) in defaults.dictionaryRepresentation() where isBackedUpSetting(key) {
            if let value = AppBackupSettingValue(defaultsObject: object) { settings[key] = value }
        }

        return AppBackupExtras(
            breakdowns: breakdownStore.allBreakdowns(),
            breakdownUserNotes: userNotes,
            savedKanji: savedKanjiStore.kanji,
            singHistory: SingHistoryStore.shared.allRecords(),
            segmentationDemotions: defaults.string(forKey: SegmentationDemotions.storageKey),
            lyricsTranslations: translations,
            guessedGlosses: GuessedGlossStore.shared.allGlosses(),
            compositeGlosses: GuessedGlossStore.composite.allGlosses(),
            settings: settings,
            apiKeys: options.includeAPIKeys ? currentAPIKeys() : nil,
            stemFiles: options.includeStems ? stemFileNames() : []
        )
    }

    // The folder the stem cache keeps its files in, nil when Application Support is unavailable.
    static func stemsDirectory() -> URL? {
        VocalStemCache.directoryForStorageManagement()
    }

    // Names of the regular files in the stem cache, sorted for a stable backup.
    static func stemFileNames() -> [String] {
        guard let directory = stemsDirectory() else { return [] }
        return OptionalFileRead.contents(of: directory, logAs: .backup)
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map(\.lastPathComponent)
            .sorted()
    }

    // Writes a validated snapshot into the stores. Each area is replaced as a whole, so an import
    // leaves exactly the backup's contents. Stem files are copied from `stemsSource` when given.
    static func apply(
        _ extras: AppBackupExtras,
        stemsSource: URL?,
        breakdownStore: SongBreakdownStore,
        savedKanjiStore: SavedKanjiStore
    ) {
        let defaults = UserDefaults.standard
        breakdownStore.replaceAll(with: extras.breakdowns)
        savedKanjiStore.replaceAll(with: extras.savedKanji)
        SingHistoryStore.shared.replaceAll(with: extras.singHistory)
        GuessedGlossStore.shared.replaceAll(with: extras.guessedGlosses)
        GuessedGlossStore.composite.replaceAll(with: extras.compositeGlosses)

        if let demotions = extras.segmentationDemotions {
            defaults.set(demotions, forKey: SegmentationDemotions.storageKey)
        } else {
            defaults.removeObject(forKey: SegmentationDemotions.storageKey)
        }

        removeKeys(withPrefix: breakdownNoteKeyPrefix)
        for (noteID, text) in extras.breakdownUserNotes {
            defaults.set(text, forKey: breakdownNoteKeyPrefix + noteID)
        }
        removeKeys(withPrefix: translationKeyPrefix)
        for (attachmentID, translations) in extras.lyricsTranslations {
            defaults.set(translations, forKey: translationKeyPrefix + attachmentID)
        }

        // Only allow-listed keys are written, so a hand-edited backup cannot overwrite arbitrary defaults.
        for (key, value) in extras.settings where isBackedUpSetting(key) {
            defaults.set(value.defaultsObject, forKey: key)
        }

        if let apiKeys = extras.apiKeys {
            restoreAPIKeys(apiKeys)
        }
        if let stemsSource {
            restoreStems(from: stemsSource, names: extras.stemFiles)
        }
    }

    // The API keys currently stored, by backup name; unset keys are left out.
    private static func currentAPIKeys() -> [String: String] {
        var keys: [String: String] = [:]
        keys["openai"] = LLMSettings.apiKey(for: .openAI)
        keys["claude"] = LLMSettings.apiKey(for: .claude)
        keys["jimaku"] = JimakuSettings.apiKey()
        return keys
    }

    // Stores the backup's API keys in the Keychain and bumps the revision counter so the open
    // Settings screen re-reads them.
    private static func restoreAPIKeys(_ keys: [String: String]) {
        for (name, value) in keys where apiKeyAccounts.contains(name) {
            switch name {
            case "openai": LLMSettings.setAPIKey(value, for: .openAI)
            case "claude": LLMSettings.setAPIKey(value, for: .claude)
            default: JimakuSettings.setAPIKey(value)
            }
        }
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: LLMSettings.keysRevisionKey) + 1, forKey: LLMSettings.keysRevisionKey)
    }

    // Copies the backup's stem files into the stem cache, replacing same-named files; a failed
    // copy is logged and skipped because a missing stem only costs a re-isolation later.
    private static func restoreStems(from source: URL, names: [String]) {
        guard let directory = stemsDirectory() else { return }
        for name in names {
            let destination = directory.appendingPathComponent(name)
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: destination)
            } catch {
                AppLog.error(.backup, "import: stem \(name) not restored — \(error.localizedDescription)")
            }
        }
        VocalStemCache.enforceBudget()
    }

    // Removes every UserDefaults key that starts with `prefix`, so a restore does not leave
    // entries for songs the backup does not contain.
    private static func removeKeys(withPrefix prefix: String) {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
