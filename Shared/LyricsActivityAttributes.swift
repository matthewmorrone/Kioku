import ActivityKit
import Foundation

// One piece of a lyric line with furigana: `text` is a run of the line; `ruby` is its reading when
// the run is kanji that takes furigana, nil for everything else.
nonisolated struct LyricsActivityRubyRun: Codable, Hashable, Sendable {
    let text: String
    let ruby: String?
}

// The changing part of the lyrics Live Activity, pushed by the app on every line change and
// play/pause. Kept small: ActivityKit caps a content update at 4KB.
nonisolated struct LyricsActivityState: Codable, Hashable, Sendable {
    // The line being sung, split into furigana runs. A single run without ruby when the app has
    // no readings for it.
    let line: [LyricsActivityRubyRun]
    // The following line as plain text, shown dimmed under the current one; nil at the last line.
    let nextLine: String?
    let isPlaying: Bool
}

// The fixed part of the lyrics Live Activity: the note playing. Compiled into BOTH the app (which
// starts and updates the activity) and the widget extension (which renders it).
nonisolated struct LyricsActivityAttributes: ActivityAttributes {
    typealias ContentState = LyricsActivityState
    let title: String
}
