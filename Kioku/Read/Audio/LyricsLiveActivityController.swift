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
    // What `update(activityID:content:)` reports when iOS no longer has the activity.
    nonisolated private static let goneOutcome = "skipped: activity gone"
    // Numbers each update in the debug log, pairing a sent line with when ActivityKit accepted it.
    private var updateNumber = 0

    // Whether this controller has a Live Activity up, so the playback controller can leave the Now
    // Playing card off while it is.
    var isShowing: Bool { activity != nil }

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
            let id = activity.id
            updateNumber += 1
            let number = updateNumber
            AppLog.info(.audioPlayback, "[LyricsLiveActivityController] update #\(number): \(state.line.map(\.text).joined()) playing=\(state.isPlaying)")
            // Updates go out independently, not queued behind each other: lines are seconds apart, so
            // ordering isn't at risk, while a queue would let one slow ActivityKit call freeze every
            // later line.
            Task { [weak self] in
                let started = Date()
                let outcome = await Self.update(activityID: id, content: content)
                AppLog.info(.audioPlayback, "[LyricsLiveActivityController] update #\(number) \(outcome) after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                // iOS dropped the activity: forget it, so the next foreground play starts a new one
                // instead of updating a banner that no longer exists.
                if outcome == Self.goneOutcome, self?.activity?.id == id {
                    self?.activity = nil
                    self?.lastState = nil
                }
            }
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
        let id = activity.id
        Task { await Self.end(activityID: id) }
    }

    // Ends activities left over from a previous launch (the app was killed mid-song), which this
    // instance has no handle to and would otherwise sit frozen on the Lock Screen for hours.
    private static func endOrphanedActivities() {
        for id in Activity<LyricsActivityAttributes>.activities.map(\.id) {
            Task { await end(activityID: id) }
        }
    }

    // Activity isn't Sendable, so a handle held on the main actor can't cross into the async
    // ActivityKit call. These re-fetch the activity by id inside the nonisolated call instead.
    // Returns what happened for the debug log: the activity's state when updated, or that iOS no
    // longer has it (dismissed by the user or ended by the system).
    nonisolated private static func update(activityID: String, content: ActivityContent<LyricsActivityState>) async -> String {
        guard let activity = Activity<LyricsActivityAttributes>.activities.first(where: { $0.id == activityID }) else {
            return goneOutcome
        }
        let stateBefore = activity.activityState
        await activity.update(content)
        return "applied (state \(stateBefore))"
    }

    // Ends the activity with the given id immediately; see `update(activityID:content:)` for why
    // it goes by id.
    nonisolated private static func end(activityID: String) async {
        guard let activity = Activity<LyricsActivityAttributes>.activities.first(where: { $0.id == activityID }) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }
}
