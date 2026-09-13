import Foundation

// Collects streamed text fragments off the main actor and returns the text up to the last
// newline each time a fragment completes at least one new line (nil otherwise), so partial
// parses only ever see whole lines.
nonisolated final class StreamedLineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var linesEmitted = 0

    // Appends a fragment; returns the complete-line prefix when it has grown by a line.
    nonisolated func append(_ delta: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        text += delta
        guard let lastNewline = text.lastIndex(of: "\n") else { return nil }
        let prefix = String(text[...lastNewline])
        let lines = prefix.split(separator: "\n", omittingEmptySubsequences: false).count - 1
        guard lines > linesEmitted else { return nil }
        linesEmitted = lines
        return prefix
    }
}
