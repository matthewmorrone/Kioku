import Foundation
import Combine

// Background worker that runs LLMCorrectionService on a list of notes one at
// a time and writes the corrected segmentation back via NotesStore. Used by
// the bulk-import sheet so a freshly-imported batch can get AI-corrected
// segmentation without blocking the import UI or coupling the queue to a
// live ReadView. The view-bound apply path (ReadView+LLMCorrection) still
// owns the pending-changes UX when the user opens a single note; this queue
// just lands corrections on disk in the background.
@MainActor
final class LLMCorrectionQueue: ObservableObject {
    // Notes still waiting to start; head of the queue is processed next.
    @Published private(set) var pendingNoteIDs: [UUID] = []
    // Note currently being processed, if any. Drives the "X of Y" UI surface.
    @Published private(set) var currentNoteID: UUID?
    // Notes whose correction call or apply step failed. Surfaced as a count
    // on the Notes tab (badge) so the user can re-trigger or ignore.
    @Published private(set) var failedNoteIDs: Set<UUID> = []
    // Most recent failure's user-facing message. Displayed in the status
    // banner so the user can see WHY a correction failed (context overflow,
    // network error, etc.) instead of just a silent count.
    @Published private(set) var lastFailureMessage: String?
    // Notes whose correction completed successfully since the last reset.
    @Published private(set) var successCount: Int = 0
    // Snapshot of the total queued at the start of the current run, used by
    // the status banner to render "X of Y" progress. Cleared once the queue
    // drains so the next batch starts from zero.
    @Published private(set) var runTotal: Int = 0
    // Notes processed (success or failure) in the current run. Resets when
    // the queue drains so the banner can show "X of Y" for the next batch.
    @Published private(set) var runCompletedCount: Int = 0

    private weak var store: NotesStore?
    private var runner: Task<Void, Never>?
    private let service = LLMCorrectionService()

    // Captures the store so the queue can resolve notes and persist corrections
    // without re-entering the SwiftUI environment chain from inside async work.
    init(store: NotesStore? = nil) {
        self.store = store
    }

    // Binds the queue to a notes store after both have been constructed. Used
    // because ContentView's @StateObject initializers can't reference each other
    // at declaration time (same pattern as NotesStore's deferred wiring).
    func attach(store: NotesStore) {
        self.store = store
    }

    // True while at least one note is being processed or waiting.
    var isProcessing: Bool { runner != nil }
    // Total notes in flight including the one currently processing.
    var totalQueued: Int {
        pendingNoteIDs.count + (currentNoteID != nil ? 1 : 0)
    }

    // Adds notes to the queue and starts processing if no runner is active.
    // Dedupes against the current head and existing pending entries so a
    // user who re-imports the same item doesn't queue duplicate work.
    func enqueue(noteIDs: [UUID]) {
        guard noteIDs.isEmpty == false else { return }
        let novel = noteIDs.filter { id in
            id != currentNoteID && pendingNoteIDs.contains(id) == false
        }
        guard novel.isEmpty == false else { return }
        pendingNoteIDs.append(contentsOf: novel)
        runTotal += novel.count
        startIfNeeded()
    }

    // Clears the failed-note set and the surfaced failure message after the
    // user has seen the banner.
    func acknowledgeFailures() {
        failedNoteIDs.removeAll()
        lastFailureMessage = nil
    }

    // Resets the success counter — used when the badge is dismissed so the
    // next batch starts from zero in the UI. Also clears the per-run counters
    // since "dismiss" means "I'm done looking at this batch."
    func resetSuccessCount() {
        successCount = 0
        runTotal = 0
        runCompletedCount = 0
    }

    // Spins up the background processing task if one isn't already running.
    // Idempotent — re-entered every time enqueue() lands new work, which is
    // safe because the active runner drains everything currently pending.
    private func startIfNeeded() {
        guard runner == nil else { return }
        runner = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.processLoop()
            self.runner = nil
        }
    }

    // Drains the queue head-first, running each note's correction in turn.
    // Per-note errors are caught and recorded so a single failure can't kill
    // the loop or block the rest of the batch.
    private func processLoop() async {
        while pendingNoteIDs.isEmpty == false {
            let next = pendingNoteIDs.removeFirst()
            currentNoteID = next
            do {
                try await processOne(noteID: next)
                successCount += 1
            } catch {
                failedNoteIDs.insert(next)
                lastFailureMessage = error.localizedDescription
                print("[LLMCorrectionQueue] failed for note \(next): \(error.localizedDescription)")
            }
            currentNoteID = nil
            runCompletedCount += 1
        }
    }

    // Loads the note, sends its content to the LLM as a degenerate
    // single-segment-per-line compact format, then persists the corrected
    // segmentation back via NotesStore. The model is instructed to re-segment
    // from scratch and emit readings, so it doesn't need an existing
    // segmentation to begin from — feeding it the raw lines lets the queue
    // run without taking a dependency on the Segmenter.
    private func processOne(noteID: UUID) async throws {
        guard let store, let note = store.note(withID: noteID) else { return }
        let trimmed = note.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }

        let compact = Self.compactFormat(forContent: note.content)
        let response = try await service.requestCorrections(compactSegments: compact)

        guard let ranges = LLMCorrectionApplier.segmentRanges(
            from: response,
            originalText: note.content
        ) else {
            throw LLMCorrectionError.decodingError(
                "Corrected segments could not be reconciled with note content."
            )
        }

        _ = store.scheduleReadEditorPersist(
            id: noteID,
            title: note.title,
            content: note.content,
            segments: ranges,
            segmentsAreUserEdited: false
        )
    }

    // Encodes the note's raw content as one segment per source line in the
    // compact format LLMCorrectionService expects, with no readings. Blank
    // lines become bare `N|` entries, matching the parser's blank-line rule.
    static func compactFormat(forContent content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            let n = index + 1
            if line.isEmpty {
                out.append("\(n)|")
            } else {
                out.append("\(n)|\(line)|")
            }
        }
        return out.joined(separator: "\n")
    }
}
