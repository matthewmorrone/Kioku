import Foundation

// Renders the Read tab's segmentation of a note as the breakdown request's "Segmentation"
// section (SongBreakdownPrompt rule 12), so the model's word bullets follow the app's word
// boundaries and readings instead of its own — the breakdown's word list then lines up with
// the words the user taps on the page. One row per non-blank note line, numbered the way the
// prompt numbers lines: `Line 3: 夢[ゆめ] | を | 見[み]た`, a reading in brackets right after the
// kanji run it covers.
enum SongBreakdownSegmentation {

    // The section body, or "" when the snapshot carries no segmentation for its text — the
    // request then goes out without a Segmentation section and the model segments on its own.
    static func section(from snapshot: NoteReadingSnapshot) -> String {
        guard snapshot.isUsable(for: snapshot.text) else { return "" }
        var rows: [String] = []
        var lineNumber = 0
        var lineStart = 0
        for line in snapshot.text.components(separatedBy: "\n") {
            let lineRange = NSRange(location: lineStart, length: line.utf16.count)
            lineStart += line.utf16.count + 1
            guard line.trimmingCharacters(in: .whitespaces).isEmpty == false else { continue }
            lineNumber += 1
            rows.append("Line \(lineNumber): " + segments(in: lineRange, of: snapshot).joined(separator: " | "))
        }
        return rows.joined(separator: "\n")
    }

    // The line's segments in order, each with its readings inlined; whitespace-only segments
    // are left out since they aren't words.
    private static func segments(in lineRange: NSRange, of snapshot: NoteReadingSnapshot) -> [String] {
        let text = snapshot.text as NSString
        let lineEnd = lineRange.location + lineRange.length
        var words: [String] = []
        for segment in snapshot.segmentRanges {
            let ns = NSRange(segment, in: snapshot.text)
            let start = max(ns.location, lineRange.location)
            let end = min(ns.location + ns.length, lineEnd)
            guard end > start else { continue }
            let word = annotated(NSRange(location: start, length: end - start), in: text, snapshot: snapshot)
            if word.trimmingCharacters(in: .whitespaces).isEmpty == false {
                words.append(word.trimmingCharacters(in: .whitespaces))
            }
        }
        return words
    }

    // The segment's surface with each reading inside it written in brackets after its run.
    private static func annotated(_ range: NSRange, in text: NSString, snapshot: NoteReadingSnapshot) -> String {
        let end = range.location + range.length
        let readings = snapshot.furiganaBySegmentLocation
            .filter { $0.key >= range.location && $0.key < end }
            .sorted { $0.key < $1.key }
        var result = ""
        var cursor = range.location
        for (location, reading) in readings {
            let length = snapshot.furiganaLengthBySegmentLocation[location] ?? 0
            let runEnd = min(location + length, end)
            guard location >= cursor, runEnd > location else { continue }
            result += text.substring(with: NSRange(location: cursor, length: runEnd - cursor)) + "[\(reading)]"
            cursor = runEnd
        }
        result += text.substring(with: NSRange(location: cursor, length: end - cursor))
        return result
    }
}
