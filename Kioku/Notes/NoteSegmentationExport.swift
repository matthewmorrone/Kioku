import Foundation

// The note list's "pipe-segmented" export: each source line as `N|seg|seg|`, with kanji runs
// annotated `(kanji)[reading]`, so word boundaries and readings can be reviewed or pasted
// elsewhere as plain text.
enum NoteSegmentationExport {
    // Encodes segments line by line. Each content line is `N|seg1|seg2|`, N the 1-based source line;
    // the line break itself encodes one "\n", and a bare `N|` line encodes an extra blank line.
    // Example: A\nB\n\nC → `1|A|\n2|B|\n3|\n4|C|`
    static func compactText(from entries: [NoteSegmentationExportEntry]) -> String {
        var outputLines: [String] = []
        var currentTokens: [String] = []
        // Whether the last emitted line was a content line rather than a bare line-number marker.
        var lastWasContent = false
        // 1-based source line, advanced on every "\n" segment.
        var sourceLine = 1

        for entry in entries {
            if entry.surface == "\n" {
                if currentTokens.isEmpty == false {
                    outputLines.append("\(sourceLine)|" + currentTokens.joined(separator: "|") + "|")
                    currentTokens = []
                    lastWasContent = true
                } else if lastWasContent {
                    // A second "\n" in a row (a blank line): a bare line-number marker.
                    outputLines.append("\(sourceLine)|")
                    lastWasContent = false
                }
                sourceLine += 1
            } else {
                currentTokens.append(token(for: entry))
            }
        }
        if currentTokens.isEmpty == false {
            outputLines.append("\(sourceLine)|" + currentTokens.joined(separator: "|") + "|")
        }
        return outputLines.joined(separator: "\n")
    }

    // One segment as a token, each kanji run annotated `(kanji)[reading]` when its reading is known.
    static func token(for entry: NoteSegmentationExportEntry) -> String {
        guard ScriptClassifier.containsKanji(entry.surface) else { return entry.surface }
        let runs = FuriganaAttributedString.kanjiRuns(in: entry.surface)
        let characters = Array(entry.surface)
        guard runs.isEmpty == false else { return entry.surface }
        let runReadings = FuriganaAttributedString.normalizedRunReadings(surface: entry.surface, reading: entry.reading, runs: runs)

        var result = ""
        var index = 0
        for (runIndex, run) in runs.enumerated() {
            if index < run.start { result += String(characters[index..<run.start]) }
            let runSurface = String(characters[run.start..<run.end])
            let reading = runReadings?[runIndex] ?? ""
            result += reading.isEmpty ? runSurface : "(\(runSurface))[\(reading)]"
            index = run.end
        }
        if index < characters.count { result += String(characters[index...]) }
        return result
    }
}

// One segment for NoteSegmentationExport: its surface and full kana reading (empty for none).
struct NoteSegmentationExportEntry {
    let surface: String
    let reading: String
}
