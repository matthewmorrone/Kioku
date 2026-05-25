import Foundation

// AppStorage key + default for the clipboard-lookup auto-detect toggle.
//
// Privacy context: when auto-detect is on, ClipboardLookupCoordinator reads
// UIPasteboard.general.string to filter for Japanese on every app focus —
// which triggers iOS's "Pasted from X" notification. Users who prefer not to
// see that notification can opt out via this toggle; checkClipboard() then
// short-circuits before ever calling .string, restoring the iOS-banner-free
// behavior.
nonisolated enum ClipboardSettings {
    // UserDefaults key for the auto-detect toggle. Shared between
    // SettingsView's @AppStorage binding and ClipboardLookupCoordinator's
    // injected-defaults read so both sides observe the same value.
    static let autoDetectKey = "clipboardLookup.autoDetectEnabled"

    // Default: on, matching the prior implicit behavior of the coordinator.
    // Existing users see no change unless they turn it off.
    static let defaultAutoDetect = true
}
