import SwiftUI

// The top bar's gear button (LyricsView+ReAlignBar.swift) opens this in place (a popover anchored
// to the button, forced off the iPhone's default full-sheet adaptation) instead of jumping to the
// Settings tab — the toggles a user is likely to want mid-listen, without leaving the lyric
// view. Not private: called from LyricsView+ReAlignBar.swift.
extension LyricsView {
    var settingsPopup: some View {
        VStack(alignment: .leading, spacing: 14) {
            LyricsPlaybackOptions()

            Picker("Track By", selection: $quickGranularityRaw) {
                Text("Line").tag(LyricsHighlightGranularity.sentence.rawValue)
                Text("Word").tag(LyricsHighlightGranularity.word.rawValue)
            }
            .pickerStyle(.segmented)

            Divider()

            Toggle("Translation", isOn: $isTranslationVisible)
            // The word bubbles, with a menu of what they cover; more options go in the menu.
            HStack {
                Text("Bubbles")
                Menu {
                    LyricWordFilterMenuItems()
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .disabled(showsBubbles == false)
                Spacer()
                Toggle("Bubbles", isOn: $showsBubbles)
                    .labelsHidden()
            }
            Toggle("Segmentation", isOn: $isSegmentationVisible)
            Toggle("Furigana", isOn: $isFuriganaVisible)
        }
        .padding(16)
        .frame(width: 270)
    }
}
