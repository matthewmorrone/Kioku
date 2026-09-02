import Foundation

// Thread-safe text buffer for a streamed LLM response. URLSession hands fragments to the
// stream consumer off the main actor, and the breakdown services re-parse the buffer at line
// granularity — so this box owns the accumulation, decides when a fragment is worth a
// re-parse (it completed a line), and remembers the last emitted parse so identical
// results (blank lines, whitespace-only fragments) don't fan out redundant UI updates.
nonisolated final class StreamedTextAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var lastEmittedLines: [SongLine] = []

    // Appends a fragment and returns the full buffer when the fragment completed at least one
    // line, nil otherwise. Callers parse the returned snapshot; per-token parsing would be
    // wasted work since a line card can't change until its markdown line is complete.
    func append(_ fragment: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        text += fragment
        return fragment.contains("\n") ? text : nil
    }

    // Records a parse result and reports whether it differs from the previous one. The
    // Equatable compare is cheap relative to the parse that produced it and keeps the
    // main-actor hop out of the hot path for no-op lines.
    func recordEmitted(_ lines: [SongLine]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard lines != lastEmittedLines else { return false }
        lastEmittedLines = lines
        return true
    }
}
