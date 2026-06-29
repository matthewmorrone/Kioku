import Foundation
import Combine

// Tracks the in-flight progress of a single LLM correction request, the way
// LLMCorrectionQueue tracks progress across notes. The per-line Apple
// Intelligence path can take ~3s per call and 15+ calls per long note, so
// without surfacing per-line progress the spinner reads as "stuck."
//
// Lives as a singleton because the only producer is AppleIntelligenceCorrection-
// Client (a static enum, no instance state) and the only consumer is the
// floating CorrectionProgressOverlay. A pure @EnvironmentObject would require
// threading it through every async boundary; a static .shared keeps the
// surface area minimal.
@MainActor
final class AICorrectionProgress: ObservableObject {
    static let shared = AICorrectionProgress()

    // Number of lines completed in the current request (success or skip).
    @Published private(set) var current: Int = 0
    // Total lines that will be processed in this request. Zero when idle.
    @Published private(set) var total: Int = 0
    // 0-based index of the note line the model is processing RIGHT NOW, or
    // nil when no line is in flight. Drives the per-line in-flight highlight
    // in ReadView so the user can see which line the AI is currently
    // reviewing. Distinct from `current` (which counts completed lines)
    // because the index can skip values (bare blank lines aren't dispatched
    // but still occupy a line in the note text).
    @Published private(set) var currentLineIndex: Int? = nil

    private init() {}

    // True while a request is in flight. Drives banner visibility.
    var isActive: Bool { total > 0 }

    // Starts a new run. Resets counters; called once per requestCorrections call
    // before the per-line loop begins.
    func begin(total: Int) {
        self.current = 0
        self.total = max(0, total)
        self.currentLineIndex = nil
    }

    // Marks the start of work on a specific note-text line. Used by the per-
    // line in-flight highlight; cleared on advance() so the highlight follows
    // the cursor through the note as each line completes.
    func startLine(at index: Int) {
        currentLineIndex = index
    }

    // Records one line as done — success, skipped, or failed all count.
    func advance() {
        current = min(current + 1, max(total, current + 1))
        currentLineIndex = nil
    }

    // Marks the run as finished. Called from a defer so it fires on both
    // success and throw paths, clearing the banner cleanly either way.
    func finish() {
        current = 0
        total = 0
        currentLineIndex = nil
    }
}
