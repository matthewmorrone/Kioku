import Foundation

// Settings scoped to the karaoke lyrics popup only (LyricsView) — deliberately NOT shared with
// ReadView/SettingsPreviewRenderer's TypographySettings.showFuriganaKey/colorAlternationKey.
// An earlier version reused those keys so toggling here would "follow the user back to Read",
// but having both ReadView and LyricsView hold live @AppStorage bindings to the same key —
// each driving its own KiokuCoreTextRendererView instance simultaneously — produced a genuine
// infinite AttributeGraph update cycle (deterministic SIGSEGV at launch, confirmed by bisecting
// against a clean pre-change baseline build, 2026-09-22). Keeping these independent trades away
// the cross-tab mirroring for a working app.
enum LyricsPopupSettings {
    static let showTranslationKey = "kioku.settings.lyricsPopup.showTranslation"
    static let defaultShowTranslation = true

    static let showFuriganaKey = "kioku.settings.lyricsPopup.showFurigana"
    static let defaultShowFurigana = true

    static let showSegmentationKey = "kioku.settings.lyricsPopup.showSegmentation"
    static let defaultShowSegmentation = true
}
