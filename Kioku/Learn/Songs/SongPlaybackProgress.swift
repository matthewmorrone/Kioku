import Foundation

// Cross-session playback progress for a note's breakdown mini player, persisted directly to
// UserDefaults. SongLiveListenController itself is deliberately ephemeral — a fresh
// SongStepperView instance gets a fresh controller with no memory of where playback left off
// (see its own header comment) — so this is the one place that intentionally outlives it,
// letting the mini player and intro/outro playback resume where the user left off after
// closing the breakdown or relaunching the app. A stateless enum of static functions rather
// than an ObservableObject/EnvironmentObject: nothing here needs to publish changes to a
// SwiftUI view — SongStepperView reads it once (on appear) and writes to it on change.
enum SongPlaybackProgress {
    // The mini player's last known step (intro / a line / outro) for a note, nil if it's
    // never been played.
    static func lastStep(forNoteID id: UUID) -> SongPlaybackStep? {
        guard let raw = UserDefaults.standard.string(forKey: stepKey(id)) else { return nil }
        return SongPlaybackStep.from(persistedValue: raw)
    }

    // Called whenever the mini player's current step changes, so it survives an app relaunch.
    static func recordStep(_ step: SongPlaybackStep, forNoteID id: UUID) {
        UserDefaults.standard.set(step.persistedValue, forKey: stepKey(id))
    }

    // The intro/outro player's last playhead: an absolute millisecond offset into the note's
    // own audio file (valid for either range — intro [0, firstLine) and outro [lastLine,
    // duration) never overlap). 0 for a note that's never played its intro/outro.
    static func lastIntroOutroPositionMs(forNoteID id: UUID) -> Int {
        UserDefaults.standard.integer(forKey: introOutroPositionKey(id))
    }

    // Called when the breakdown view disappears while the intro/outro player has a loaded
    // source, so leaving mid-intro/outro and reopening resumes from there.
    static func recordIntroOutroPosition(_ ms: Int, forNoteID id: UUID) {
        UserDefaults.standard.set(ms, forKey: introOutroPositionKey(id))
    }

    // Drops all saved progress for a note — call when a regenerate replaces the breakdown the
    // saved step/position was measured against, so stale progress can't resume into text that
    // no longer exists.
    static func clear(forNoteID id: UUID) {
        UserDefaults.standard.removeObject(forKey: stepKey(id))
        UserDefaults.standard.removeObject(forKey: introOutroPositionKey(id))
    }

    // UserDefaults key for a note's saved mini player step.
    private static func stepKey(_ id: UUID) -> String { "songListen.step.\(id.uuidString)" }
    // UserDefaults key for a note's saved intro/outro playhead.
    private static func introOutroPositionKey(_ id: UUID) -> String { "songListen.introOutroPositionMs.\(id.uuidString)" }
}
