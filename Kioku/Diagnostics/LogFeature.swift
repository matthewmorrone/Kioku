import Foundation

// Central registry of the app's loggable feature areas. Every AppLog call site names one of
// these, so a single case here is the one place that both (a) defines the os.Logger category a
// feature's output lands under — enabling `log stream --predicate 'category == "llmCorrection"'`
// / Console filtering — and (b) drives the per-feature on/off toggle in Settings → Debug Logs
// (LogFeatureSettings). Adding a new instrumented feature means adding one case here, not
// inventing another bespoke log file.
enum LogFeature: String, CaseIterable, Identifiable {
    case llmCorrection
    case bridgeServer
    case dictionaryDownload
    case transcription
    case notesImport
    case backup
    case wordOfTheDay
    case clipboardLookup
    case segmentation
    case audioAlignment

    var id: String { rawValue }

    // Human-readable label for the Settings toggle list.
    var displayName: String {
        switch self {
        case .llmCorrection: return "LLM Correction"
        case .bridgeServer: return "Bridge Server"
        case .dictionaryDownload: return "Dictionary Download"
        case .transcription: return "Transcription"
        case .notesImport: return "Notes Import (OCR / URL / Bulk)"
        case .backup: return "Backup Export / Import"
        case .wordOfTheDay: return "Word of the Day"
        case .clipboardLookup: return "Clipboard Lookup"
        case .segmentation: return "Segmentation Engine"
        case .audioAlignment: return "Audio Alignment / Karaoke"
        }
    }

    // One-line description of what a feature's logs cover, shown under its toggle so a user
    // deciding whether to silence a noisy feature knows what they're giving up.
    var detail: String {
        switch self {
        case .llmCorrection: return "System/user prompts, raw provider responses, parse and salvage steps."
        case .bridgeServer: return "Incoming HTTP requests/responses on the local-network bridge."
        case .dictionaryDownload: return "Dictionary archive fetch, decompression, and install progress."
        case .transcription: return "Whisper model downloads and on-device transcription/alignment runs."
        case .notesImport: return "OCR capture, URL text import, and bulk import runs."
        case .backup: return "App backup export, import, and validation."
        case .wordOfTheDay: return "Word-of-the-day scheduling and notification decisions."
        case .clipboardLookup: return "Clipboard-triggered dictionary lookups."
        case .segmentation: return "MeCab/lattice segmentation diagnostics."
        case .audioAlignment: return "Lyric/subtitle alignment and karaoke playback timing."
        }
    }
}
