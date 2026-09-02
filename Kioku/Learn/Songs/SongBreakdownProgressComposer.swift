import Foundation

// Builds the row list SongStepperView scrolls through, merging whatever the model has
// streamed so far over placeholder rows derived from the note's own text. Before generation
// every non-empty note line is a placeholder; as lines arrive they replace placeholders from
// the top, the newest one is marked `.streaming`, and the untouched remainder stays
// `.pending` below it — so the list never jumps in length and the user can watch the model
// work its way down the song.
enum SongBreakdownProgressComposer {

    // Non-empty note lines as bare SongLines numbered 1…N — the same numbering the prompt asks
    // the model to use ("exact line breaks from the source"), so placeholders and streamed
    // lines usually agree on index as well as text.
    static func pendingLines(fromNoteContent content: String) -> [SongLine] {
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
    // is highlighted and whether unreached placeholders are appended. A finished breakdown is
    // shown exactly as parsed — no placeholder tail — since any line the model dropped is a
    // prompt problem, not something a dimmed card can fix.
    static func items(
        noteContent: String,
        streamedLines: [SongLine],
        isRunning: Bool
    ) -> [SongLineDisplayItem] {
        let placeholders = pendingLines(fromNoteContent: noteContent)

        if streamedLines.isEmpty {
            guard isRunning || placeholders.isEmpty == false else { return [] }
            return placeholders.enumerated().map { offset, line in
                SongLineDisplayItem(id: "pending-\(offset)", line: line, phase: .pending)
            }
        }

        var items: [SongLineDisplayItem] = []
        items.reserveCapacity(placeholders.count)
        var cursor = 0
        for (offset, line) in streamedLines.enumerated() {
            cursor = advance(cursor, past: line, in: placeholders)
            let isLast = offset == streamedLines.count - 1
            let phase: SongLineCardPhase = (isRunning && isLast) ? .streaming : .ready
            items.append(SongLineDisplayItem(id: "line-\(line.index)-\(offset)", line: line, phase: phase))
        }

        guard isRunning, cursor < placeholders.count else { return items }
        let nextIndex = (streamedLines.last?.index ?? 0) + 1
        for (offset, placeholder) in placeholders[cursor...].enumerated() {
            let renumbered = SongLine(
                index: nextIndex + offset,
                original: placeholder.original,
                romaji: nil,
                words: [],
                gist: nil,
                grammarNote: nil,
                reference: nil
            )
            items.append(SongLineDisplayItem(id: "pending-\(cursor + offset)", line: renumbered, phase: .pending))
        }
        return items
    }

    // Consumes placeholders for one streamed line: prefers the nearest placeholder (within a
    // short window) whose text matches, so a model that skipped or merged a line resyncs on
    // the next match; otherwise consumes exactly one, keeping the tail from drifting when the
    // model paraphrases a header. Never runs past the end.
    private static func advance(_ cursor: Int, past line: SongLine, in placeholders: [SongLine]) -> Int {
        guard cursor < placeholders.count else { return cursor }
        let target = SongLineCueMatcher.normalize(line.original)
        let windowEnd = min(cursor + 4, placeholders.count)
        if target.isEmpty == false {
            for j in cursor..<windowEnd where SongLineCueMatcher.normalize(placeholders[j].original) == target {
                return j + 1
            }
        }
        return cursor + 1
    }
}
