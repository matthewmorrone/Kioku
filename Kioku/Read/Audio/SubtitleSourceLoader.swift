import Foundation
import UniformTypeIdentifiers

// One place that knows how to turn a picked file into lyric-view data, regardless of whether the
// source is an SRT subtitle track, a Praat TextGrid forced-alignment grid, or an audio file. Both
// the interactive lyric-view picker (ReadView) and the bulk importer (BulkImportRunner) load
// through here so the two flows can't silently drift apart — the unification seam for SRT/TextGrid.
nonisolated enum SubtitleSourceLoader {
    // What a picked file is, as far as the lyric view cares.
    enum Kind {
        case audio
        case srt
        case textGrid
        case unknown
    }

    // Classifies a picked file by extension first — authoritative for our two text formats — then
    // by UTType conformance so the full range of importable audio (mp3, m4a, wav, …) is accepted.
    static func classify(_ url: URL) -> Kind {
        switch url.pathExtension.lowercased() {
        case "srt": return .srt
        case "textgrid": return .textGrid
        default: break
        }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audio) {
            return .audio
        }
        return .unknown
    }

    // Reads a (possibly security-scoped) text file and decodes it with decodeText. Throws only
    // when the file itself can't be read.
    static func readText(from url: URL) throws -> String {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        return decodeText(try Data(contentsOf: url))
    }

    // Decodes subtitle/TextGrid bytes, falling back UTF-8 → UTF-16 → Latin-1 so a file saved in
    // an unusual encoding still loads instead of hard-failing. Latin-1 maps every byte, so this
    // always produces text. Shared by readText and SRTDocument.
    static func decodeText(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        if let latin1 = String(data: data, encoding: .isoLatin1) { return latin1 }
        return String(decoding: data, as: UTF8.self)
    }

    // Parses SRT text into cues.
    static func parseSRT(_ text: String) -> [SubtitleCue] {
        SubtitleParser.parse(text)
    }

    // Derives line-level cues from a TextGrid's lowest-resolution IntervalTier so a `.TextGrid` can
    // stand in for an SRT when no subtitle file is supplied. The coarsest tier (fewest spans) is the
    // line/phrase tier; finer tiers (words, phones) drive karaoke checkpoints, not cue text.
    static func deriveCues(fromTextGrid content: String) throws -> [SubtitleCue] {
        try TextGridParser.parse(content).lineCues()
    }

    // Parses a TextGrid and binds per-cue character checkpoints against the supplied cues. Returns
    // nil (logged) when the file is unparseable so callers can skip it — a TextGrid is an optional
    // karaoke companion, never a hard requirement.
    static func bindCheckpoints(textGridContent content: String, cues: [SubtitleCue]) -> CueCharTimings? {
        do {
            return TextGridBinder.bindCheckpoints(document: try TextGridParser.parse(content), cues: cues)
        } catch {
            AppLog.error(.audioAlignment, "TextGrid did not parse; skipping karaoke checkpoints — \(error)")
            return nil
        }
    }
}

extension UTType {
    // Praat TextGrid forced-alignment files. `nonisolated` for the same reason as `subripText`:
    // this type is referenced from nonisolated importer code under Swift 6. Falls back to plainText
    // when the system has no registered type for the extension (over-permissive in the importer
    // filter is harmless — classify() re-checks the extension).
    nonisolated static let praatTextGrid: UTType = UTType(filenameExtension: "TextGrid") ?? .plainText
}
