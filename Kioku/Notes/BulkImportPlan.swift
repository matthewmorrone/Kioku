import Foundation

// Captures one filename-grouped batch of files queued for bulk import.
// All URLs in an item share the same basename (case-insensitive, ignoring extension).
// The combination of which URLs are present determines the action the runner will take.
// `id` is the lowercased trimmed basename so it stays stable across plan recomputations
// while the sheet is open — this is what lets per-item progress survive store mutations.
struct BulkImportPlanItem: Identifiable, Equatable {
    var id: String
    var baseName: String
    var textURL: URL?
    var subtitleURL: URL?
    var audioURL: URL?
    // Praat TextGrid companion — when present, the runner parses it for per-cue character
    // checkpoints and saves them alongside the cues for karaoke-style sub-line highlighting.
    var textGridURL: URL?
    // Set when an audio file's basename matches an existing note's title, so the
    // runner attaches audio (and any companion subtitle) rather than creating a new note.
    var matchedExistingNoteID: UUID?
}

// Runtime state of a single plan item during a bulk import run.
// `.failed` carries a user-facing reason so the sheet can surface row-level errors.
enum BulkImportItemStatus: Equatable {
    case queued
    case running
    case completed
    case failed(String)
}

// Per-item snapshot used by the sheet to render the running plan as it executes.
// `transcriptionProgress` only applies to items running Whisper inference.
struct BulkImportItemProgress: Identifiable, Equatable {
    var id: String
    var baseName: String
    var status: BulkImportItemStatus
    var transcriptionProgress: Double
    // What the engine is currently doing (e.g. "Isolating vocals…", "Transcribing vocals…"), shown
    // above the progress bar. Empty until the transcription service reports a stage.
    var statusLabel: String = ""
}
