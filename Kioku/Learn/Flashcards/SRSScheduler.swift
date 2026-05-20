import Foundation

// Streak-based fixed-interval SRS scheduler. Given the current stats and the answer the user gave,
// returns the new due date and the new consecutive-correct streak. Pure function, no I/O.
// Intervals (in seconds): a wrong answer drops the streak to 0 (10 minute relearn step), a correct
// answer advances along [1d, 3d, 7d, 14d, 30d, 90d, 180d]. Picked over SM-2 because the steps
// are easy to reason about and the state survives JSON round-trips without floating-point drift.
nonisolated enum SRSScheduler {
    // The two grades the existing flashcard UI surfaces.
    enum Answer {
        case correct
        case again
    }

    // Result of scheduling: the next due date and the new streak counter.
    struct ScheduleResult: Equatable {
        let dueDate: Date
        let consecutiveCorrect: Int
    }

    // Fixed interval ladder. Index 0 is the relearn step (used right after "again" or for the
    // very first review). Index 7+ caps at 180 days so cards don't drift years out.
    private static let intervalSeconds: [TimeInterval] = [
        10 * 60,            // 10 minutes — relearn step
        24 * 60 * 60,       // 1 day
        3 * 24 * 60 * 60,   // 3 days
        7 * 24 * 60 * 60,   // 7 days
        14 * 24 * 60 * 60,  // 14 days
        30 * 24 * 60 * 60,  // 30 days
        90 * 24 * 60 * 60,  // 90 days
        180 * 24 * 60 * 60  // 180 days (cap)
    ]

    // Returns the next schedule given the existing stats and the user's answer.
    static func schedule(
        previous: ReviewWordStats?,
        answer: Answer,
        now: Date = Date()
    ) -> ScheduleResult {
        let priorStreak = previous?.consecutiveCorrect ?? 0
        let newStreak: Int
        let intervalIndex: Int

        switch answer {
        case .correct:
            newStreak = priorStreak + 1
            // Streak 1 → 1 day (index 1); streak 6+ → 180 days (last index).
            intervalIndex = min(newStreak, intervalSeconds.count - 1)
        case .again:
            newStreak = 0
            intervalIndex = 0
        }

        let nextDue = now.addingTimeInterval(intervalSeconds[intervalIndex])
        return ScheduleResult(dueDate: nextDue, consecutiveCorrect: newStreak)
    }

    // Human-readable label for the next-up interval — e.g. "1d", "10m". Used by the UI to preview
    // what tapping "Know" will cost the user in calendar time.
    static func intervalLabel(for streak: Int) -> String {
        let idx = min(max(streak, 0), intervalSeconds.count - 1)
        let seconds = intervalSeconds[idx]
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}
