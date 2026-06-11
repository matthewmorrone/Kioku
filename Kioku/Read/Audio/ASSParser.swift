import Foundation

// Parses Advanced SubStation Alpha (.ass / .ssa) subtitle content into SubtitleCues — the dominant
// anime subtitle format, which SubtitleParser (SRT-only) can't read. Pure parsing/formatting with
// no UI or shared mutable state, so it's `nonisolated` and safe to call from background contexts
// (the subtitle-import task), mirroring SubtitleParser's contract.
//
// ASS dialogue lives in the [Events] section. A "Format:" line there declares the column order, and
// each "Dialogue:" line carries those columns comma-separated — but the final Text column may itself
// contain commas, so we split only up to the Text column's index and keep the remainder verbatim.
// Inline override tags ({\i1}, {\pos(...)}, …) and ASS line-break escapes (\N, \n, \h) are stripped
// so the emitted cue text is clean Japanese, matching what SRT cues look like downstream.
nonisolated enum ASSParser {
    // Parses ASS/SSA content into timed cues in file order. Returns [] when there is no usable
    // [Events] section so callers can treat an unparseable file the same as an empty subtitle track.
    static func parse(_ assContent: String) -> [SubtitleCue] {
        let lines = assContent
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var inEvents = false
        // Column indices resolved from the [Events] "Format:" line. ASS files almost always order
        // these as Start,End,…,Text, but the Format line is authoritative so we read it rather than
        // assuming positions.
        var startColumn: Int?
        var endColumn: Int?
        var textColumn: Int?
        var cues: [SubtitleCue] = []
        var index = 1

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Section headers look like "[Events]", "[Script Info]", etc.
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inEvents = line.caseInsensitiveCompare("[Events]") == .orderedSame
                continue
            }
            guard inEvents else { continue }

            if line.hasPrefix("Format:") {
                let columns = line.dropFirst("Format:".count)
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                startColumn = columns.firstIndex(of: "start")
                endColumn = columns.firstIndex(of: "end")
                textColumn = columns.firstIndex(of: "text")
                continue
            }

            guard line.hasPrefix("Dialogue:") else { continue }
            guard let startCol = startColumn, let endCol = endColumn, let textCol = textColumn else {
                continue
            }

            // Split into exactly textCol+1 fields: the first textCol commas are real separators, and
            // everything after the textCol-th comma is the Text field (which may contain commas).
            let payload = String(line.dropFirst("Dialogue:".count))
            let fields = splitFields(payload, keepingTailFrom: textCol)
            guard fields.count > textCol,
                  let startMs = parseTimecode(fields[startCol]),
                  let endMs = parseTimecode(fields[endCol]) else {
                continue
            }

            let text = cleanDialogueText(fields[textCol])
            guard text.isEmpty == false else { continue }

            cues.append(SubtitleCue(index: index, startMs: startMs, endMs: endMs, text: text))
            index += 1
        }

        return cues
    }

    // Splits a Dialogue payload on commas, but stops splitting once `tailColumn` fields have been
    // produced so the final Text field retains any commas it contains.
    private static func splitFields(_ payload: String, keepingTailFrom tailColumn: Int) -> [String] {
        var fields: [String] = []
        var current = ""
        for character in payload {
            if character == "," && fields.count < tailColumn {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current)
        return fields
    }

    // Strips ASS override blocks ({...}) and converts line-break / hard-space escapes to spaces so the
    // cue text is plain readable dialogue. Drawing-mode shapes inside override blocks are removed with
    // the block. Leaves the Japanese text otherwise untouched.
    private static func cleanDialogueText(_ raw: String) -> String {
        var result = ""
        var insideTag = false
        for character in raw {
            switch character {
            case "{": insideTag = true
            case "}": insideTag = false
            default:
                if insideTag == false { result.append(character) }
            }
        }
        return result
            .replacingOccurrences(of: "\\N", with: " ")
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\h", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Converts an ASS timecode "H:MM:SS.cc" (centiseconds, one-digit hours) to milliseconds. Returns
    // nil for malformed stamps so the Dialogue line is skipped rather than crashing the import.
    // Shares SubtitleTimecode with the SRT path — fraction-width padding makes centiseconds work.
    private static func parseTimecode(_ raw: String) -> Int? {
        SubtitleTimecode.parseToMilliseconds(raw)
    }
}
