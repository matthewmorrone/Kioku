import Foundation

enum DictionarySettings {
    static let includeArchaicReadingsKey = "kioku.settings.dictionary.includeArchaicReadings"
    static let defaultIncludeArchaicReadings = false

    // Read the toggle from UserDefaults, falling back to the default when the key has never
    // been written — @AppStorage in SettingsView only persists once the user touches the row.
    // The explicit nil-check avoids the NSNumber-vs-Bool footgun in `object(forKey:) as? Bool`.
    // When false (the default) the word detail reading switcher hides readings whose entry is
    // entirely archaic/obsolete/rare (e.g. うだく for 抱く); when true every homograph reading shows.
    static var includeArchaicReadings: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: includeArchaicReadingsKey) != nil else {
            return defaultIncludeArchaicReadings
        }
        return defaults.bool(forKey: includeArchaicReadingsKey)
    }

    static let showJapaneseInPopoverKey = "kioku.settings.dictionary.showJapaneseInPopover"
    static let defaultShowJapaneseInPopover = true

    // When false, the segment-tap popover shows a speaker icon instead of the tapped word's
    // surface text — still speaks the same word on tap, just without spoiling it visually.
    static var showJapaneseInPopover: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: showJapaneseInPopoverKey) != nil else {
            return defaultShowJapaneseInPopover
        }
        return defaults.bool(forKey: showJapaneseInPopoverKey)
    }

    static let prefersSheetDirectSegmentActionsKey = "kioku.settings.dictionary.prefersSheetDirectSegmentActions"
    static let defaultPrefersSheetDirectSegmentActions = false

    // When true, tapping a word skips the lightweight popover and opens the full lookup sheet
    // directly — same destination the popover's chevron escalates to, just reached in one tap.
    static var prefersSheetDirectSegmentActions: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: prefersSheetDirectSegmentActionsKey) != nil else {
            return defaultPrefersSheetDirectSegmentActions
        }
        return defaults.bool(forKey: prefersSheetDirectSegmentActionsKey)
    }
}
