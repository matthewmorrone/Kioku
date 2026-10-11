import Foundation

enum DictionarySettings {
    // Whether the word detail reading switcher offers readings whose entry is entirely
    // archaic/obsolete/rare (e.g. うだく for 抱く). There is no Settings control: every homograph
    // reading shows. The switcher still filters on this, so setting it to false hides them again.
    static let includeArchaicReadings = true

    static let showJapaneseInPopoverKey = "kioku.settings.dictionary.showJapaneseInPopover"
    static let defaultShowJapaneseInPopover = true

    // When false, the segment-tap popover shows a speaker icon instead of the tapped word's
    // surface text — still speaks the same word on tap, just without spoiling it visually.
    static var showJapaneseInPopover: Bool {
        UserDefaultsBool.read(showJapaneseInPopoverKey, default: defaultShowJapaneseInPopover)
    }

    static let prefersSheetDirectSegmentActionsKey = "kioku.settings.dictionary.prefersSheetDirectSegmentActions"
    static let defaultPrefersSheetDirectSegmentActions = false

    // When true, tapping a word skips the lightweight popover and opens the full lookup sheet
    // directly — same destination the popover's chevron escalates to, just reached in one tap.
    static var prefersSheetDirectSegmentActions: Bool {
        UserDefaultsBool.read(prefersSheetDirectSegmentActionsKey, default: defaultPrefersSheetDirectSegmentActions)
    }
}
