import Combine
import Foundation

// Persists per-song learning-journey progress. Mirrors the UserDefaults pattern used by
// ReviewStore and WordsStore so all "study state" stays in one storage layer.
@MainActor
final class SongJourneyStore: ObservableObject {
    @Published private(set) var statesByNote: [UUID: SongJourneyState] = [:]

    private let storageKey = "kioku.songjourney.v1"

    init() {
        StartupTimer.measure("SongJourneyStore.init") {
            load()
        }
    }

    // Returns the existing state for a song or a fresh default one. Does not persist.
    func state(for noteID: UUID) -> SongJourneyState {
        statesByNote[noteID] ?? SongJourneyState(noteID: noteID)
    }

    // Marks a stage visited (used for L1, which has no score).
    func markVisited(noteID: UUID, stage: SongJourneyStage) {
        var state = state(for: noteID)
        state.visitedStages.insert(stage)
        if stage.passingScore == nil {
            state.completedStages.insert(stage)
        }
        state.lastActiveStage = stage
        state.updatedAt = Date()
        save(state)
    }

    // Records a score for a stage. Only keeps the best score, and marks the stage complete when
    // the score meets the stage's passing threshold.
    func recordScore(noteID: UUID, stage: SongJourneyStage, score: Double) {
        var state = state(for: noteID)
        state.visitedStages.insert(stage)
        let previous = state.bestScoreByStage[stage] ?? -1
        if score > previous {
            state.bestScoreByStage[stage] = score
        }
        if let threshold = stage.passingScore, score >= threshold {
            state.completedStages.insert(stage)
        }
        state.lastActiveStage = stage
        state.updatedAt = Date()
        save(state)
    }

    // Records the stage the diagnostic recommends starting from.
    func setRecommendedStart(noteID: UUID, stage: SongJourneyStage) {
        var state = state(for: noteID)
        state.recommendedStartStage = stage
        state.updatedAt = Date()
        save(state)
    }

    // Tracks the stage the user most recently interacted with so the journey can scroll or
    // highlight it on the next visit.
    func setLastActive(noteID: UUID, stage: SongJourneyStage) {
        var state = state(for: noteID)
        state.lastActiveStage = stage
        state.updatedAt = Date()
        save(state)
    }

    // Writes the per-note state into the in-memory map and flushes the whole map to disk so a
    // crash or force-quit never leaves the published state ahead of UserDefaults.
    private func save(_ state: SongJourneyState) {
        statesByNote[state.noteID] = state
        persist()
    }

    // Restores all per-song journey states on init. Silently ignores malformed entries so a
    // partial corruption in one note's state doesn't drop the others.
    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([String: SongJourneyState].self, from: data)
        else {
            statesByNote = [:]
            return
        }
        var result: [UUID: SongJourneyState] = [:]
        for (key, value) in decoded {
            if let uuid = UUID(uuidString: key) { result[uuid] = value }
        }
        statesByNote = result
    }

    // Encodes the in-memory map with String keys because JSON requires string-keyed objects.
    private func persist() {
        var encodable: [String: SongJourneyState] = [:]
        for (id, state) in statesByNote {
            encodable[id.uuidString] = state
        }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
