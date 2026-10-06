import ActivityKit
import Foundation
import UIKit

// Owns the lyrics Live Activity (Lock Screen banner + Dynamic Island, rendered by the widget
// extension's LyricsLiveActivity). AudioPlaybackController calls `sync` whenever the line or play
// state changes; this class decides whether to start, update, or end the activity so the playback
// controller stays free of ActivityKit details.
@MainActor
final class LyricsLiveActivityController {
    private var activity: Activity<LyricsActivityAttributes>?
    // Last state sent, so repeated syncs with the same line (seeks within a line, timer-driven
    // Now Playing refreshes) don't spend ActivityKit's update budget.
    private var lastState: LyricsActivityState?
    // Orphan cleanup must run once per launch, not once per instance: SongStepperView makes its
    // own AudioPlaybackController, and its init would otherwise end the Read screen's live activity.
    private static var didEndOrphanedActivities = false

    init() {
        guard Self.didEndOrphanedActivities == false else { return }
        Self.didEndOrphanedActivities = true
        Self.endOrphanedActivities()
    }

    // Brings the activity in line with playback. A nil `state` (nothing loaded, stopped) or the
    // setting being off ends it. Starting needs the app in the foreground — ActivityKit refuses
    // requests from the background — so a play from the lock screen with no activity yet just
    // waits for the next foreground play.
    func sync(title: String?, state: LyricsActivityState?) {
        guard let state, AudioSettings.lyricsLiveActivityEnabled else {
            end()
            return
        }
        if let activity {
            guard state != lastState else { return }
            lastState = state
            let content = ActivityContent(state: state, staleDate: nil)
            Task { await activity.update(content) }
            return
        }
        guard state.isPlaying,
              UIApplication.shared.applicationState == .active,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: LyricsActivityAttributes(title: title ?? "Kioku"),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            lastState = state
        } catch {
            AppLog.error(.audioPlayback, "[LyricsLiveActivityController] request failed: \(error.localizedDescription)")
        }
    }

    // Removes the activity immediately — a lyrics banner for a song that is no longer loaded is
    // just clutter, so there's no lingering "ended" state.
    func end() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    // Ends activities left over from a previous launch (the app was killed mid-song), which this
    // instance has no handle to and would otherwise sit frozen on the Lock Screen for hours.
    private static func endOrphanedActivities() {
        for activity in Activity<LyricsActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
