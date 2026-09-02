import Foundation

// Builds the row list SongStepperView scrolls through, merging whatever the model has
// streamed so far over the note's own lines. Before generation every non-empty note line is
// a card on its own; as breakdown lines arrive they take over those cards from the top, the
// newest one is marked `.streaming`, and the untouched remainder below keeps showing the note
// text — so the list never jumps in length and the user can watch the model work its way
// down the song.
enum SongBreakdownProgressComposer {

    // Non-empty note lines as bare SongLines numbered 1…N — the same numbering the prompt asks
    // the model to use ("exact line breaks from the source"), so note lines and streamed
    // lines usually agree on index as well as text.
    static func noteLines(fromNoteContent content: String) -> [SongLine] {
        var lines: [SongLine] = []
        for raw in content.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty == false else { continue }
            lines.append(SongLine(
                index: lines.count + 1,
                original: trimmed,
                romaji: nil,
                words: [],
                gist: nil,
                grammarNote: nil,
                reference: nil
            ))
        }
        return lines
    }

    // Composes the display rows. `streamedLines` is the partial parse while running, or the
    // finished breakdown's lines when not; `isRunning` decides whether the last streamed line
    // is highlighted and whether the unreached note lines are appended. A finished breakdown
    // is shown exactly as parsed — no note-line tail — since any line the model dropped is a
    // prompt problem, not something the view can paper over.
    static func items(
        noteContent: String,
        streamedLines: [SongLine],
        isRunning: Bool
    ) -> [SongLineDisplayItem] {
        let noteLines = noteLines(fromNoteContent: noteContent)

        if streamedLines.isEmpty {
            return noteLines.enumerated().map { offset, line in
                SongLineDisplayItem(id: "note-\(offset)", line: line, phase: .noteText)
            }
        }

        var items: [SongLineDisplayItem] = []
        items.reserveCapacity(noteLines.count)
        var cursor = 0
        for (offset, line) in streamedLines.enumerated() {
            cursor = advance(cursor, past: line, in: noteLines)
            let isLast = offset == streamedLines.count - 1
            let phase: SongLineCardPhase = (isRunning && isLast) ? .streaming : .ready
            items.append(SongLineDisplayItem(id: "line-\(line.index)-\(offset)", line: line, phase: phase))
        }

        guard isRunning, cursor < noteLines.count else { return items }
        let nextIndex = (streamedLines.last?.index ?? 0) + 1
        for (offset, noteLine) in noteLines[cursor...].enumerated() {
            let renumbered = SongLine(
                index: nextIndex + offset,
                original: noteLine.original,
                romaji: nil,
                words: [],
                gist: nil,
                grammarNote: nil,
                reference: nil
            )
            items.append(SongLineDisplayItem(id: "note-\(cursor + offset)", line: renumbered, phase: .noteText))
        }
        return items
    }

    // Consumes note lines for one streamed line: prefers the nearest note line (within a
    // short window) whose text matches, so a model that skipped or merged a line resyncs on
    // the next match; otherwise consumes exactly one, keeping the tail from drifting when the
    // model paraphrases a header. Never runs past the end.
    private static func advance(_ cursor: Int, past line: SongLine, in noteLines: [SongLine]) -> Int {
        guard cursor < noteLines.count else { return cursor }
        let target = SongLineCueMatcher.normalize(line.original)
        let windowEnd = min(cursor + 4, noteLines.count)
        if target.isEmpty == false {
            for j in cursor..<windowEnd where SongLineCueMatcher.normalize(noteLines[j].original) == target {
                return j + 1
            }
        }
        return cursor + 1
    }
}
