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

    enum LoadError: Error {
        case unreadable
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

    // Reads a (possibly security-scoped) text file, falling back through common encodings so an
    // unusual SRT/TextGrid still loads instead of hard-failing. Mirrors SRTDocument's decode order.
    static func readText(from url: URL) throws -> String {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        if let utf8 = try? String(contentsOf: url, encoding: .utf8) { return utf8 }
        if let utf16 = try? String(contentsOf: url, encoding: .utf16) { return utf16 }
        if let latin = try? String(contentsOf: url, encoding: .isoLatin1) { return latin }
        throw LoadError.unreadable
    }

    // Parses SRT text into cues.
    static func parseSRT(_ text: String) -> [SubtitleCue] {
        SubtitleParser.parse(text)
    }

    // Derives line-level cues from a TextGrid's lowest-resolution IntervalTier so a `.TextGrid` can
    // stand in for an SRT when no subtitle file is supplied. The coarsest tier (fewest intervals)
    // is the line/phrase tier; finer tiers (words, phones) drive karaoke checkpoints, not cue text.
    static func deriveCues(fromTextGrid content: String) throws -> [SubtitleCue] {
        let grid = try TextGridParser.parse(content)
        let candidates = grid.tiers.filter { tier in
            tier.intervals.contains { $0.text.isEmpty == false }
        }
        guard let lineTier = candidates.min(by: { $0.intervals.count < $1.intervals.count }) else {
            return []
        }
        var cues: [SubtitleCue] = []
        var index = 1
        for interval in lineTier.intervals where interval.text.isEmpty == false {
            cues.append(SubtitleCue(
                index: index,
                startMs: interval.startMs,
                endMs: interval.endMs,
                text: interval.text
            ))
            index += 1
        }
        return cues
    }

    // Parses a TextGrid and binds per-cue character checkpoints against the supplied cues. Returns
    // nil when the file is unreadable/unparseable so callers can silently skip — a TextGrid is an
    // optional karaoke companion, never a hard requirement.
    static func bindCheckpoints(textGridContent content: String, cues: [SubtitleCue]) -> CueCharTimings? {
        guard let grid = try? TextGridParser.parse(content) else { return nil }
        return TextGridBinder.bindCheckpoints(textGrid: grid, cues: cues)
    }
}

extension UTType {
    // Praat TextGrid forced-alignment files. `nonisolated` for the same reason as `subripText`:
    // this type is referenced from nonisolated importer code under Swift 6. Falls back to plainText
    // when the system has no registered type for the extension (over-permissive in the importer
    // filter is harmless — classify() re-checks the extension).
    nonisolated static let praatTextGrid: UTType = UTType(filenameExtension: "TextGrid") ?? .plainText
}
