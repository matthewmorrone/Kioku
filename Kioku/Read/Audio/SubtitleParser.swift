import Foundation

// Parses SRT subtitle file content into an ordered list of SubtitleCues and assembles note content.
// Pure parsing/formatting — no UI or shared mutable state, so it's safe to call from background
// contexts (bulk import's detached task, audio decoder pipelines). Marking the type nonisolated
// opts every method out of the project's MainActor-default actor inference.
nonisolated enum SubtitleParser {
    // Parses an SRT string into cues. Offsets into note content are not stored here;
    // call resolveHighlightRanges(for:in:) separately at playback time.
    static func parse(_ srtContent: String) -> [SubtitleCue] {
        let normalizedContent = srtContent
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // Split on blank lines that separate cue blocks.
        let blocks = normalizedContent.components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []

        for block in blocks {
            let trimmedBlock = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedBlock.isEmpty == false else { continue }

            let lines = trimmedBlock.components(separatedBy: "\n")
            guard lines.count >= 3 else { continue }

            guard let index = Int(lines[0].trimmingCharacters(in: .whitespaces)) else { continue }
            guard let (startMs, endMs) = parseTimecodeRow(lines[1]) else { continue }

            let text = lines[2...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else { continue }

            cues.append(SubtitleCue(index: index, startMs: startMs, endMs: endMs, text: text))
        }

        return cues
    }

    // Joins all cue texts with newlines to form the note body.
    static func assembleNoteContent(from cues: [SubtitleCue]) -> String {
        cues.map(\.text).joined(separator: "\n")
    }

    // Resolves each cue's text to an NSRange within noteText by searching sequentially.
    // Three-tier matching: exact substring → normalized line text → positional (next note line).
    // Positional fallback ensures cues always align even when text differs (e.g. kana vs kanji).
    // Returns nil only for non-speech cues like ♪ that have no corresponding note line.
    static func resolveHighlightRanges(for cues: [SubtitleCue], in noteText: String) -> [NSRange?] {
        var searchStart = noteText.startIndex
        var lineSearchIndex = 0
        let noteLineRanges = extractNoteLineRanges(from: noteText)
        return cues.enumerated().map { (cueIdx, cue) in
            // Non-speech cues (♪) have no note line — skip.
            if isNonSpeechCue(cue.text) {
                return nil
            }

            // Tier 1: exact substring match.
            if let range = noteText.range(of: cue.text, range: searchStart..<noteText.endIndex) {
                searchStart = range.upperBound
                let ns = NSRange(range, in: noteText)
                if let matchedLineIndex = noteLineRanges.firstIndex(where: { NSIntersectionRange($0, ns).length > 0 }) {
                    lineSearchIndex = matchedLineIndex + 1
                }
                KaraokeDebugLog.log("resolver[\(cueIdx)] tier=1 cueLen=\(cue.text.utf16.count) range=[\(ns.location),\(ns.length)] cueText=\"\(cue.text.prefix(20))\"")
                return ns
            }

            // Tier 2: normalized line text comparison.
            if let fallbackRange = resolveLineBasedHighlightRange(
                for: cue,
                in: noteText,
                lineRanges: noteLineRanges,
                lineSearchIndex: &lineSearchIndex
            ) {
                if let fallbackSwiftRange = Range(fallbackRange, in: noteText) {
                    searchStart = fallbackSwiftRange.upperBound
                }
                KaraokeDebugLog.log("resolver[\(cueIdx)] tier=2 cueLen=\(cue.text.utf16.count) range=[\(fallbackRange.location),\(fallbackRange.length)] cueText=\"\(cue.text.prefix(20))\"")
                return fallbackRange
            }

            // Tier 3: positional fallback — assign to the next non-blank unmatched note line.
            while lineSearchIndex < noteLineRanges.count {
                let positionalRange = noteLineRanges[lineSearchIndex]
                lineSearchIndex += 1
                guard let swiftRange = Range(positionalRange, in: noteText) else { continue }
                let lineText = noteText[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines)
                guard lineText.isEmpty == false else { continue }
                searchStart = swiftRange.upperBound
                KaraokeDebugLog.log("resolver[\(cueIdx)] tier=3 cueLen=\(cue.text.utf16.count) range=[\(positionalRange.location),\(positionalRange.length)] cueText=\"\(cue.text.prefix(20))\"")
                return positionalRange
            }

            KaraokeDebugLog.log("resolver[\(cueIdx)] tier=nil cueLen=\(cue.text.utf16.count) cueText=\"\(cue.text.prefix(20))\"")
            return nil
        }
    }

    // Returns true for cues that represent instrumental/non-speech sections.
    // A cue qualifies when every non-whitespace character is a ♪ or ♫ — this covers
    // single-glyph cues ("♪"), doubled cues ("♪♪"), spaced cues ("♪ ♪"), and multi-line
    // cues containing only music glyphs ("♪\n♪"). Any other text character makes it speech.
    static func isNonSpeechCue(_ text: String) -> Bool {
        var sawMusicGlyph = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if scalar == "♪" || scalar == "♫" {
                sawMusicGlyph = true
                continue
            }
            return false
        }
        // Reached end with only whitespace + ♪/♫ — non-speech iff there was at least one
        // music glyph, or the whole cue was empty/whitespace (intro padding).
        return sawMusicGlyph || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Finds the note line that matches a cue's text so the cue can be highlighted during playback.
    private static func resolveLineBasedHighlightRange(
        for cue: SubtitleCue,
        in noteText: String,
        lineRanges: [NSRange],
        lineSearchIndex: inout Int
    ) -> NSRange? {
        let normalizedCueText = normalizedSubtitleMatchText(cue.text)
        guard normalizedCueText.isEmpty == false else {
            return nil
        }

        for lineIndex in lineSearchIndex..<lineRanges.count {
            let lineRange = lineRanges[lineIndex]
            guard let swiftRange = Range(lineRange, in: noteText) else {
                continue
            }

            let lineText = String(noteText[swiftRange])
            guard normalizedSubtitleMatchText(lineText) == normalizedCueText else {
                continue
            }

            lineSearchIndex = lineIndex + 1
            return lineRange
        }

        return nil
    }

    // Pre-computes NSRanges for every line in the note so cue matching can walk them without re-scanning.
    private static func extractNoteLineRanges(from noteText: String) -> [NSRange] {
        let nsText = noteText as NSString
        var lineRanges: [NSRange] = []
        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: [.byLines, .substringNotRequired]
        ) { _, substringRange, _, _ in
            lineRanges.append(substringRange)
        }
        return lineRanges
    }

    // Collapses whitespace and fullwidth spaces so cue text can be compared to note lines without formatting differences.
    private static func normalizedSubtitleMatchText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Reconstructs a well-formed SRT string from a cue list so the user can edit and re-import it.
    static func formatSRT(from cues: [SubtitleCue]) -> String {
        cues.map { cue in
            "\(cue.index)\n\(formatTimecode(cue.startMs)) --> \(formatTimecode(cue.endMs))\n\(cue.text)"
        }.joined(separator: "\n\n")
    }

    // Formats a millisecond offset as the SRT "HH:MM:SS,mmm" timecode string.
    private static func formatTimecode(_ ms: Int) -> String {
        SubtitleTimecode.formatSRT(ms)
    }

    // Parses "HH:MM:SS,mmm --> HH:MM:SS,mmm" into a (startMs, endMs) tuple.
    private static func parseTimecodeRow(_ line: String) -> (Int, Int)? {
        let parts = line.components(separatedBy: " --> ")
        guard parts.count == 2,
              let start = SubtitleTimecode.parseToMilliseconds(parts[0]),
              let end = SubtitleTimecode.parseToMilliseconds(parts[1]) else {
            return nil
        }
        return (start, end)
    }
}
