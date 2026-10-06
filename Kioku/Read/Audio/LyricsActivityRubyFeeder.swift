import SwiftUI

// The inputs LyricsActivityRubyFeeder rebuilds furigana runs from; compared as a whole so any
// change (new cues, alignment resolving, furigana arriving) triggers one rebuild.
struct LyricsActivityRubyInputs: Equatable {
    let cues: [SubtitleCue]
    let highlightRanges: [NSRange?]
    let noteText: String
    let furiganaBySegmentLocation: [Int: String]
    let furiganaLengthBySegmentLocation: [Int: Int]
}

// Zero-size background view on the Read screen that hands AudioPlaybackController per-cue furigana
// runs for the lyrics Live Activity. Lives in the view layer because the furigana tables belong to
// the open note's document; the controller only stores the result. No visible layout.
struct LyricsActivityRubyFeeder: View {
    let controller: AudioPlaybackController
    let inputs: LyricsActivityRubyInputs

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: inputs, initial: true) { _, newInputs in
                controller.cueRubyRuns = LyricsActivityRubyBuilder.runs(
                    cues: newInputs.cues,
                    highlightRanges: newInputs.highlightRanges,
                    noteText: newInputs.noteText,
                    furiganaBySegmentLocation: newInputs.furiganaBySegmentLocation,
                    furiganaLengthBySegmentLocation: newInputs.furiganaLengthBySegmentLocation
                )
            }
    }
}
