import Foundation

// Builds the row list SongStepperView scrolls through from the lines it has — the streamed
// partial parse while a generation runs, or the cached breakdown otherwise. While streaming,
// the last line is the one the model is still writing, so it is marked `.streaming` for the
// card highlight and auto-expand. Row ids are unique per position even when the model repeats
// a line number, so SwiftUI's ForEach / scrollTo never see duplicate identities.
enum SongBreakdownProgressComposer {

    // Wraps each line as a display row. `isStreaming` marks the final row as in progress; a
    // finished breakdown gets every row `.ready`.
    static func items(lines: [SongLine], isStreaming: Bool) -> [SongLineDisplayItem] {
        lines.enumerated().map { offset, line in
            let isLast = offset == lines.count - 1
            return SongLineDisplayItem(
                id: "line-\(line.index)-\(offset)",
                line: line,
                phase: (isStreaming && isLast) ? .streaming : .ready
            )
        }
    }
}
