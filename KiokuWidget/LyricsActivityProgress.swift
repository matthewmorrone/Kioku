import SwiftUI

// The lyrics Live Activity's progress row: elapsed time, a progress bar, the song's length. While
// playing, the timer and bar are driven by the system from `playbackStart`, so they move every
// second without the app sending updates; while paused they hold the paused position. Display only:
// a Live Activity can't take drags, so the bar can't be scrubbed.
struct LyricsActivityProgress: View {
    let state: LyricsActivityState

    var body: some View {
        HStack(spacing: 8) {
            if let start = state.playbackStart, state.duration > 0 {
                let range = start...start.addingTimeInterval(state.duration)
                Text(timerInterval: range, countsDown: false)
                    .frame(width: 44, alignment: .leading)
                ProgressView(timerInterval: range, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                Text(Self.clock(state.elapsed))
                    .frame(width: 44, alignment: .leading)
                ProgressView(value: min(state.elapsed, max(state.duration, 0)), total: max(state.duration, 1))
            }
            Text(Self.clock(state.duration))
                .frame(width: 44, alignment: .trailing)
        }
        .progressViewStyle(.linear)
        .tint(WidgetTheme.vermilion)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    // m:ss for a position or length in seconds, matching what Text(timerInterval:) shows.
    private static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
