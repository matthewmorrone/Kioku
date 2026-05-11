import Foundation

// Per-song learning-journey progress snapshot, persisted by SongJourneyStore.
// Keyed by note.id so each song owns an independent state.
struct SongJourneyState: Codable, Equatable {
    var noteID: UUID
    var visitedStages: Set<SongJourneyStage> = []
    var completedStages: Set<SongJourneyStage> = []
    // 0.0...1.0 best score per stage; absent when the stage was never scored.
    var bestScoreByStage: [SongJourneyStage: Double] = [:]
    var lastActiveStage: SongJourneyStage = .diagnostic
    // Set by the diagnostic. nil until the user runs (or skips) it.
    var recommendedStartStage: SongJourneyStage?
    var updatedAt: Date = Date()

    init(noteID: UUID) {
        self.noteID = noteID
    }

    // True when the stage has either been visited (L1) or scored ≥ passing threshold (others).
    func isCompleted(_ stage: SongJourneyStage) -> Bool {
        completedStages.contains(stage)
    }

    // Returns the user's best recorded score for the stage, or nil when it has never been graded.
    func bestScore(for stage: SongJourneyStage) -> Double? {
        bestScoreByStage[stage]
    }
}
