// Pure helpers that ReadView+LLMCorrection used to host for its diff/format/
// diagnostic work. None of them read or wrote ReadView's @State; lifting them
// into a namespace pulls the host extension comfortably under the file-size
// guardrail and makes the helpers reusable from tests without a SwiftUI host.

import Foundation

enum LLMCorrectionDiagnostics {

    // Returns the 1-based line and column for a UTF-16 offset in sourceText,
    // so diff entries pinpoint divergences without requiring a text editor search.
    static func lineCol(utf16Offset: Int, in sourceText: String) -> (line: Int, col: Int) {
        let nsString = sourceText as NSString
        let safeOffset = min(utf16Offset, nsString.length)
        var line = 1
        var col = 1
        for i in 0..<safeOffset {
            if nsString.character(at: i) == 0x000A { line += 1; col = 1 } else { col += 1 }
        }
        return (line, col)
    }

    // Returns the per-run display readings that would result from applying a given reading to a surface,
    // keyed by UTF-16 location. Used to compare intended display output without being fooled by
    // differences between full readings (たべる) and already-stripped ones (た).
    static func normalizedDisplayReadings(surface: String, reading: String, baseLocation: Int) -> [Int: String] {
        let chars = Array(surface)
        let runs = FuriganaAttributedString.kanjiRuns(in: surface)
        guard runs.isEmpty == false else { return [:] }

        if let runReadings = FuriganaAttributedString.normalizedRunReadings(surface: surface, reading: reading, runs: runs),
           runReadings.count == runs.count {
            var result: [Int: String] = [:]
            for (run, runReading) in zip(runs, runReadings) {
                guard runReading.isEmpty == false else { continue }
                let prefixUTF16 = String(chars[..<run.start]).utf16.count
                result[baseLocation + prefixUTF16] = runReading
            }
            return result
        }

        return [:]
    }

    // Extracts display readings from a pre-mutation furigana snapshot for comparison.
    static func snapshotDisplayReadings(from snapshot: [Int: String], for surface: String, baseLocation: Int) -> [Int: String] {
        let utf16Length = surface.utf16.count
        return snapshot.filter { loc, _ in
            loc >= baseLocation && loc < baseLocation + utf16Length
        }
    }

    // Aligns response segment surfaces to the original text by tolerating whitespace-only
    // discrepancies: substitutions (' ' ↔ '\n', tab, U+3000), insertions (response dropped a
    // whitespace char), and deletions (response added a spurious whitespace char).
    // Returns repaired entries whose concatenated surfaces exactly equal the original text,
    // or nil when a non-whitespace mismatch is encountered. Readings are preserved.
    static func repairWhitespaceMismatches(
        _ entries: [LLMSegmentEntry],
        against originalText: String
    ) -> [LLMSegmentEntry]? {
        let origNS = originalText as NSString
        var origIdx = 0
        var repaired: [LLMSegmentEntry] = []

        for entry in entries {
            let segNS = entry.surface as NSString
            var segIdx = 0
            var units: [unichar] = []

            while segIdx < segNS.length {
                let segCh = segNS.character(at: segIdx)
                if origIdx >= origNS.length {
                    // Response has extra trailing characters — accept only if whitespace.
                    guard isWhitespaceUnit(segCh) else { return nil }
                    segIdx += 1
                    continue
                }
                let origCh = origNS.character(at: origIdx)
                if origCh == segCh {
                    units.append(origCh)
                    origIdx += 1
                    segIdx += 1
                } else if isWhitespaceUnit(origCh) && isWhitespaceUnit(segCh) {
                    // Whitespace substitution — adopt the original's character.
                    units.append(origCh)
                    origIdx += 1
                    segIdx += 1
                } else if isWhitespaceUnit(origCh) {
                    // Response dropped an original whitespace char — reinsert it.
                    units.append(origCh)
                    origIdx += 1
                } else if isWhitespaceUnit(segCh) {
                    // Response added a spurious whitespace char — drop it.
                    segIdx += 1
                } else {
                    return nil
                }
            }

            let surface = String(utf16CodeUnits: units, count: units.count)
            repaired.append(LLMSegmentEntry(surface: surface, reading: entry.reading))
        }

        // Consume any trailing original whitespace the response never emitted by appending
        // to the last non-empty repaired entry.
        while origIdx < origNS.length {
            let ch = origNS.character(at: origIdx)
            guard isWhitespaceUnit(ch) else { return nil }
            guard let lastIdx = repaired.lastIndex(where: { $0.surface.isEmpty == false }) else { return nil }
            let appended = repaired[lastIdx].surface + String(utf16CodeUnits: [ch], count: 1)
            repaired[lastIdx] = LLMSegmentEntry(surface: appended, reading: repaired[lastIdx].reading)
            origIdx += 1
        }

        guard origIdx == origNS.length else { return nil }
        return repaired
    }

    // Recognized whitespace UTF-16 units for mismatch repair: ASCII space/tab/CR/LF and
    // ideographic space (U+3000), which Japanese text commonly contains.
    static func isWhitespaceUnit(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D || unit == 0x3000
    }

    // Builds a user-facing mismatch description listing the first couple of divergences
    // with line/col and a printable form of the differing characters. We deliberately cap
    // at two issues — an alert dialog can't usefully display long quoted runs of mismatched
    // text, and the user's actionable choice is always the same (retry or accept failure).
    static func mismatchDescription(original: String, reconstructed: String) -> String {
        let origUTF16 = original.utf16.count
        let reconUTF16 = reconstructed.utf16.count

        let origChars = Array(original)
        let reconChars = Array(reconstructed)

        // Walk both sequences, emitting an entry per contiguous run of divergence. A run
        // ends when characters realign or one side is exhausted. The per-run print uses a
        // bounded context window so a single huge mismatch run doesn't fill the alert.
        var issues: [String] = []
        let maxIssues = 2
        let maxRunLength = 24
        var i = 0
        let common = min(origChars.count, reconChars.count)
        while i < common && issues.count < maxIssues {
            if origChars[i] == reconChars[i] { i += 1; continue }
            let startIdx = i
            var j = i
            while j < common && origChars[j] != reconChars[j] { j += 1 }
            let runEnd = min(j, startIdx + maxRunLength)
            let origRun = String(origChars[startIdx..<runEnd])
            let reconRun = String(reconChars[startIdx..<runEnd])
            let suffix = (j - startIdx) > maxRunLength ? "…" : ""
            let (line, col) = lineCol(for: startIdx, in: origChars)
            issues.append("line \(line), col \(col): expected \(printable(origRun))\(suffix) but got \(printable(reconRun))\(suffix)")
            i = j
        }

        // A run extending past the shared prefix shows as a trailing extra/missing tail.
        if issues.count < maxIssues && origChars.count != reconChars.count {
            let (line, col) = lineCol(for: common, in: origChars)
            if origChars.count > reconChars.count {
                let tail = String(origChars[common..<origChars.count])
                issues.append("line \(line), col \(col): response is missing \(printable(tail))")
            } else {
                let tail = String(reconChars[common..<reconChars.count])
                issues.append("line \(line), col \(col): response has extra \(printable(tail))")
            }
        }

        if issues.isEmpty == false {
            let header = "LLM response doesn't match the source text (\(origUTF16) vs \(reconUTF16) UTF-16 units, \(issues.count)\(issues.count >= maxIssues ? "+" : "") issue\(issues.count == 1 ? "" : "s")):"
            return header + "\n\n• " + issues.joined(separator: "\n• ")
        }


        // No character-level difference found — one is a prefix of the other.
        let delta = reconUTF16 - origUTF16
        let sign = delta > 0 ? "+" : ""
        return "Segment surfaces don't cover the full text (\(sign)\(delta) UTF-16 units). The response likely added or dropped characters."
    }

    // Computes 1-based line and column for a character index in a [Character] array.
    // Used by the mismatch description so each reported issue points at a precise location.
    static func lineCol(for charIndex: Int, in chars: [Character]) -> (line: Int, col: Int) {
        var line = 1
        var col = 1
        let end = min(charIndex, chars.count)
        for i in 0..<end {
            if chars[i] == "\n" { line += 1; col = 1 } else { col += 1 }
        }
        return (line, col)
    }

    // Renders a run of characters as a human-readable token: whitespace and control chars
    // become escape sequences (\n, \t, \u{3000}) so invisible differences are still legible
    // in an alert, while normal characters are shown quoted.
    static func printable(_ run: String) -> String {
        guard run.isEmpty == false else { return "''" }
        var result = ""
        for scalar in run.unicodeScalars {
            switch scalar.value {
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x09: result += "\\t"
            case 0x20: result += "·"
            case 0x3000: result += "\\u{3000}"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "\\u{%X}", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return "'\(result)'"
    }

    // Emits a structured mismatch report so the divergence is immediately actionable.
    // Shows line/column, a side-by-side context window, and Unicode scalars of the
    // differing characters so invisible differences (spaces, newlines, surrogates) are visible.
    // The body is currently all-disabled logging stubs (preserved from the pre-extraction
    // version) so the report shape and computed values stay available for re-enabling later
    // without re-deriving the side-by-side context logic.
    static func printMismatchReport(
        original: String,
        reconstructed: String,
        response: LLMCorrectionResponse
    ) {
        let origChars = Array(original)
        let reconChars = Array(reconstructed)

        // Compute the line for a character index by scanning for newlines.
        func lineNumber(in chars: [Character], at idx: Int) -> Int {
            var line = 1
            for i in 0..<min(idx, chars.count) {
                if chars[i] == "\n" { line += 1 }
            }
            return line
        }

        // Logging disabled.
        if let idx = zip(origChars, reconChars).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            let line = lineNumber(in: origChars, at: idx)
            // Side-by-side context: 3 lines centred on the divergence line, aligned.
            let origLines = original.components(separatedBy: "\n")
            let reconLines = reconstructed.components(separatedBy: "\n")
            let firstLine = max(1, line - 1)
            let lastLine  = min(max(origLines.count, reconLines.count), line + 1)
            // Logging disabled.
            _ = firstLine
            _ = lastLine
        }

        // Logging disabled.
        for (i, entry) in response.segments.enumerated() {
            let scalarStr = entry.surface.unicodeScalars.map { "U+\(String($0.value, radix: 16, uppercase: true))" }.joined(separator: " ")
            _ = i
            _ = scalarStr
            // Logging disabled.
        }
    }

    // Encodes [LLMSegmentEntry] to compact human-readable format for LLM I/O.
    // Each content line is `N|seg1|seg2|` where N is the 1-based source line number.
    // The line break itself encodes a single `\n`.
    // A bare `N|` line encodes an extra blank line (i.e. `\n\n` between surrounding content).
    // Example: A\nB\n\nC\n → `1|A|\n2|B|\n3|\n4|C|`
    static func buildCompactFormat(from entries: [LLMSegmentEntry]) -> String {
        var outputLines: [String] = []
        var currentTokens: [String] = []
        // Tracks whether the last emitted line was a content line (vs a bare line-number marker).
        var lastWasContent = false
        // 1-based source line counter — increments each time a \n segment is consumed.
        var sourceLine = 1

        for entry in entries {
            if entry.surface == "\n" {
                if currentTokens.isEmpty == false {
                    // Flush pending content; the line break encodes this \n implicitly.
                    outputLines.append("\(sourceLine)|" + currentTokens.joined(separator: "|") + "|")
                    currentTokens = []
                    lastWasContent = true
                } else if lastWasContent {
                    // Second consecutive \n (blank line) — emit a bare line-number marker.
                    outputLines.append("\(sourceLine)|")
                    lastWasContent = false
                }
                // A third+ consecutive \n would need additional bare markers.
                // For now song/prose text only has at most double newlines.
                sourceLine += 1
            } else {
                currentTokens.append(compactToken(for: entry))
            }
        }
        if currentTokens.isEmpty == false {
            outputLines.append("\(sourceLine)|" + currentTokens.joined(separator: "|") + "|")
        }

        return outputLines.joined(separator: "\n")
    }

    // Formats a single segment entry as a compact token, annotating kanji runs as `(kanji)[reading]`.
    static func compactToken(for entry: LLMSegmentEntry) -> String {
        guard ScriptClassifier.containsKanji(entry.surface) else {
            return entry.surface
        }
        let runs = FuriganaAttributedString.kanjiRuns(in: entry.surface)
        let chars = Array(entry.surface)
        guard runs.isEmpty == false else { return entry.surface }

        let runReadings = FuriganaAttributedString.normalizedRunReadings(surface: entry.surface, reading: entry.reading, runs: runs)

        var result = ""
        var charIdx = 0
        for (runIdx, run) in runs.enumerated() {
            if charIdx < run.start {
                result += String(chars[charIdx..<run.start])
            }
            let runSurface = String(chars[run.start..<run.end])
            let reading = runReadings?[runIdx] ?? ""
            result += reading.isEmpty ? runSurface : "(\(runSurface))[\(reading)]"
            charIdx = run.end
        }
        if charIdx < chars.count {
            result += String(chars[charIdx...])
        }
        return result
    }
}
