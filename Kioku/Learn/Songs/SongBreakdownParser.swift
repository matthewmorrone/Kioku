import Foundation

// Parses the markdown produced by the song-breakdown prompt into a list of SongLine values.
// Tolerant of whitespace, blank lines, alternate dash characters, and minor formatting drift.
// Splits on markdown horizontal rules (---, ***, ___) and parses each section independently;
// sections without a recognizable "**Line N:**" header are skipped (covers title blocks,
// model preambles, trailing notes, etc.).
final class SongBreakdownParser {

    // Returns the parsed lines or throws when no section yielded a recognizable header.
    // Caller wraps these in a SongBreakdown with hash/date/provider metadata.
    func parse(markdown: String) throws -> [SongLine] {
        let sections = splitSections(markdown)
        var parsed: [SongLine] = []
        for section in sections {
            if let line = parseSection(section) {
                parsed.append(line)
            }
        }
        guard parsed.isEmpty == false else {
            throw SongBreakdownParseError.noLinesParsed
        }
        return parsed
    }

    // Splits the input into one section per line-header so each section can be parsed
    // independently. Two split signals are honoured:
    //   1. Markdown horizontal rules (---, ***, ___) on their own line — these always start
    //      a fresh section.
    //   2. A `**Line N:` header — when we encounter one while the current section already
    //      holds a header, we split there too. This is the load-bearing case: models
    //      frequently omit horizontal rules and just stack `**Line N:**` blocks one after
    //      another, and without this implicit boundary every line after the first would
    //      leak into Line 1's grammar-note tail.
    private func splitSections(_ markdown: String) -> [String] {
        let lines = markdown.components(separatedBy: "\n")
        var sections: [[String]] = [[]]
        var currentHasHeader = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                sections.append([])
                currentHasHeader = false
                continue
            }
            if parseHeader(trimmed) != nil {
                if currentHasHeader {
                    sections.append([])
                }
                currentHasHeader = true
            }
            sections[sections.count - 1].append(line)
        }
        return sections
            .map { $0.joined(separator: "\n") }
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }

    // Parses a section into one SongLine. Returns nil when no header is found in this section.
    // Each non-blank line is classified into header / romaji / bullet / gist / reference /
    // grammar-note; unknown lines accumulate as the grammar note tail.
    private func parseSection(_ section: String) -> SongLine? {
        let rawLines = section.components(separatedBy: "\n")

        var headerIndex: Int? = nil
        var headerOriginal: String? = nil
        var cursor: Int = 0
        for (i, line) in rawLines.enumerated() {
            if let parsed = parseHeader(line) {
                headerIndex = parsed.index
                headerOriginal = parsed.original
                cursor = i + 1
                break
            }
        }
        guard let lineIndex = headerIndex, let original = headerOriginal else {
            return nil
        }

        var romaji: String? = nil
        var words: [SongWord] = []
        var gist: String? = nil
        var grammarParts: [String] = []
        var reference: LineReference? = nil

        for i in cursor..<rawLines.count {
            let raw = rawLines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if let ref = parseReference(trimmed) {
                reference = ref
                continue
            }
            if romaji == nil, let extracted = parseRomajiLine(trimmed) {
                romaji = extracted
                continue
            }
            if let word = parseBullet(trimmed) {
                words.append(word)
                continue
            }
            if let extracted = parseGist(trimmed) {
                gist = extracted
                continue
            }
            grammarParts.append(trimmed)
        }

        let grammarNote: String? = grammarParts.isEmpty
            ? nil
            : grammarParts.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        return SongLine(
            index: lineIndex,
            original: original,
            romaji: romaji,
            words: words,
            gist: gist,
            grammarNote: grammarNote,
            reference: reference
        )
    }

    // Parses "**Line N: <original>**" → (N, <original>). Tolerates `**Line N:** <original>` too,
    // surrounding whitespace, and missing trailing markers.
    private func parseHeader(_ raw: String) -> (index: Int, original: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let prefix = "**Line "
        guard trimmed.hasPrefix(prefix) else { return nil }
        let afterPrefix = trimmed.dropFirst(prefix.count)
        guard let colonIdx = afterPrefix.firstIndex(of: ":") else { return nil }
        let numberStr = String(afterPrefix[..<colonIdx]).trimmingCharacters(in: .whitespaces)
        guard let parsedIndex = Int(numberStr) else { return nil }
        var rest = String(afterPrefix[afterPrefix.index(after: colonIdx)...])
            .trimmingCharacters(in: .whitespaces)
        // Some variants close the bold immediately after the colon: `**Line N:** original`
        if rest.hasPrefix("**") {
            rest = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        if rest.hasSuffix("**") {
            rest = String(rest.dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        return (parsedIndex, rest)
    }

    // Accepts a single-asterisk italic line like `*kimi no namae wo yonda*`. Rejects bold
    // (`**...**`) so `**Gist:**` lines and the header don't get pulled in.
    private func parseRomajiLine(_ raw: String) -> String? {
        guard raw.count > 2 else { return nil }
        guard raw.hasPrefix("*"), raw.hasSuffix("*") else { return nil }
        guard raw.hasPrefix("**") == false, raw.hasSuffix("**") == false else { return nil }
        let inner = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        return inner.isEmpty ? nil : inner
    }

    // Parses one bullet `- **<surface>** (<sungRomaji>) — <definition>`. Tolerates `*` bullet,
    // missing parens or em-dash, and en-dash / double-hyphen alternates.
    private func parseBullet(_ raw: String) -> SongWord? {
        let bulletPrefixes = ["- ", "* ", "• "]
        var content = raw
        var matched = false
        for prefix in bulletPrefixes {
            if content.hasPrefix(prefix) {
                content = String(content.dropFirst(prefix.count))
                matched = true
                break
            }
        }
        guard matched else { return nil }

        guard content.hasPrefix("**") else { return nil }
        let afterOpen = content.dropFirst(2)
        guard let closeRange = afterOpen.range(of: "**") else { return nil }
        let surface = String(afterOpen[..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let afterSurface = String(afterOpen[closeRange.upperBound...])
            .trimmingCharacters(in: .whitespaces)

        var sungRomaji = ""
        var remainder = afterSurface
        if remainder.hasPrefix("(") {
            if let endParen = remainder.firstIndex(of: ")") {
                sungRomaji = String(remainder[remainder.index(after: remainder.startIndex)..<endParen])
                    .trimmingCharacters(in: .whitespaces)
                remainder = String(remainder[remainder.index(after: endParen)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        // Strip an optional separator dash between the romaji and the definition.
        // Order matters: longer alternatives must precede their substrings.
        let dashAlternates: [String] = ["—", "–", "--", "-", ":"]
        for dash in dashAlternates {
            if remainder.hasPrefix(dash) {
                remainder = String(remainder.dropFirst(dash.count))
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }

        return SongWord(surface: surface, sungRomaji: sungRomaji, definition: remainder)
    }

    // Recognizes `**Gist:** text`, `**Gist**: text`, or the plain `Gist: text` form.
    private func parseGist(_ raw: String) -> String? {
        let markers = ["**Gist:**", "**Gist**:", "Gist:"]
        for marker in markers {
            if raw.hasPrefix(marker) {
                return String(raw.dropFirst(marker.count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // Recognizes "= line N" and "Parallel to line N with substitution: X → Y".
    // Strips bold/italic markers so emphasized variants still match.
    private func parseReference(_ raw: String) -> LineReference? {
        let stripped = raw.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let n = parseSameAsLine(stripped) {
            return .sameAsLine(n)
        }
        if let parallel = parseParallelTo(stripped) {
            return parallel
        }
        return nil
    }

    // Matches "= line N" / "=line N" / "Same as line N" and returns the referenced index.
    private func parseSameAsLine(_ stripped: String) -> Int? {
        let lower = stripped.lowercased()
        let prefixes = ["= line ", "=line ", "same as line "]
        for p in prefixes {
            guard lower.hasPrefix(p) else { continue }
            let rest = stripped.dropFirst(p.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: " .,"))
            let digits = rest.prefix(while: { $0.isNumber })
            if let n = Int(digits) {
                return n
            }
        }
        return nil
    }

    // Matches "Parallel to line N" with optional "with substitution: X → Y" tail and returns
    // the referenced index plus the substitution clause (empty when omitted).
    private func parseParallelTo(_ stripped: String) -> LineReference? {
        let lower = stripped.lowercased()
        let prefix = "parallel to line "
        guard lower.hasPrefix(prefix) else { return nil }
        let rest = stripped.dropFirst(prefix.count)
        let digits = String(rest.prefix(while: { $0.isNumber }))
        guard let n = Int(digits) else { return nil }
        let afterDigits = String(rest.dropFirst(digits.count))
        if let range = afterDigits.range(of: "substitution:", options: .caseInsensitive) {
            let sub = String(afterDigits[range.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " .,"))
            return .parallelTo(line: n, substitution: sub)
        }
        return .parallelTo(line: n, substitution: "")
    }
}

// Surfaces parser failures distinctly so the UI can decide how to react: a refusal or
// completely-different-shape response throws `noLinesParsed`, which we show alongside the
// raw text in a debug overlay.
enum SongBreakdownParseError: LocalizedError {
    case noLinesParsed
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .noLinesParsed:
            return "No song lines could be parsed from the response."
        case .unexpected(let message):
            return "Unexpected breakdown format: \(message)"
        }
    }
}
