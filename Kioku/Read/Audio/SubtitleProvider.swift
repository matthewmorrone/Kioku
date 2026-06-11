import Foundation

// One subtitle search result, provider-agnostic. Whatever the backend, the search UI only ever sees
// this shape. `detail` is a short provider-formatted secondary line (e.g. "Show name · 1.2 MB" for
// Jimaku, or "JA · 1234 downloads" for a download-count provider) so the UI stays decoupled from
// provider-specific fields. `downloadToken` is the opaque handle download() needs — for Jimaku it's
// the file's direct URL.
struct SubtitleSearchResult: Identifiable, Sendable {
    let id: String
    // Primary line: the subtitle file / release name.
    let releaseName: String
    // Secondary line: provider-formatted context (source show, size, language, popularity…).
    let detail: String
    // Opaque provider handle used by download().
    let downloadToken: String
}

// Result of a successful download: where the file landed locally plus an optional remaining-quota
// count for providers that cap downloads (nil for providers with no daily cap, like Jimaku).
struct SubtitleDownload: Sendable {
    let fileURL: URL
    let remainingDownloads: Int?
}

// The extensible seam for Feature B. Today there is exactly one conformer (JimakuProvider); adding
// another provider is a new file implementing this protocol with zero changes to the search UI or
// the download→extract handoff. `search` returns provider-ranked results; `download` fetches one to
// a local temp file that feeds straight into Feature A's SubtitleVocabExtractor.
protocol SubtitleProvider: Sendable {
    var id: String { get }
    // Returns provider-ranked results for a title (+ optional season/episode; providers ignore
    // dimensions they don't model — Jimaku has no season concept).
    func search(title: String, season: Int?, episode: Int?) async throws -> [SubtitleSearchResult]
    // Fetches one result to a local temp file plus any remaining-quota count.
    func download(_ result: SubtitleSearchResult) async throws -> SubtitleDownload
}

// The subtitle container formats the import pipeline can parse: SubtitleParser handles SRT,
// ASSParser handles ASS/SSA. Single source of truth so the download accept-list and the
// user-facing error message can never disagree (the message used to drop ".ssa").
nonisolated enum SubtitleFormat {
    static let supportedExtensions = ["srt", "ass", "ssa"]

    // Human-readable list for error copy, e.g. ".srt, .ass, .ssa".
    static var supportedListDescription: String {
        supportedExtensions.map { ".\($0)" }.joined(separator: ", ")
    }
}

// Errors surfaced to the search UI as readable messages.
enum SubtitleProviderError: LocalizedError {
    case notConfigured
    case badResponse
    case noDownloadLink
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add your Jimaku API key in Settings first."
        case .badResponse: return "The subtitle provider returned an unexpected response."
        case .noDownloadLink: return "No download link was returned for that file."
        case .unsupportedFormat(let ext): return "Can't read “.\(ext)” subtitles — only \(SubtitleFormat.supportedListDescription) are supported."
        }
    }
}
