import ActivityKit
import SwiftUI
import WidgetKit

// Declares the lyrics Live Activity the app starts while a note with timed lyrics plays: the Lock
// Screen banner and the Dynamic Island presentations. The app pushes every line change as a local
// update (LyricsLiveActivityController), so nothing here schedules or fetches.
struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LyricsLiveActivityView(title: context.attributes.title, state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LyricsPlayingIndicator(isPlaying: context.state.isPlaying)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        LyricsLineView(state: context.state, baseSize: 18, rubySize: 8,
                                       baseColor: AnyShapeStyle(.primary), rubyColor: AnyShapeStyle(.secondary))
                        LyricsActivityProgress(state: context.state)
                        LyricsActivityControls(isPlaying: context.state.isPlaying)
                    }
                }
            } compactLeading: {
                Image(systemName: "music.note")
                    .foregroundStyle(WidgetTheme.vermilion)
            } compactTrailing: {
                LyricsPlayingIndicator(isPlaying: context.state.isPlaying)
            } minimal: {
                Image(systemName: "music.note")
                    .foregroundStyle(WidgetTheme.vermilion)
            }
        }
    }
}
