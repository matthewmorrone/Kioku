import Combine
import SwiftUI

// Zero-size background view that maps AudioPlaybackController cue changes to
// ReadView's playbackHighlightRangeOverride and activePlaybackCueIndex bindings.
// Kept separate from ReadView so the observer lifecycle is explicit and isolated.
struct AudioCueHighlightObserver: View {
    @ObservedObject var controller: AudioPlaybackController
    let highlightRanges: [NSRange?]
    @Binding var playbackHighlightRangeOverride: NSRange?
    @Binding var activePlaybackCueIndex: Int?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                updateHighlight(for: controller.activeCueIndex, isPlaying: controller.isPlaying)
            }
            .onReceive(controller.$activeCueIndex.combineLatest(controller.$isPlaying)) { newIndex, isPlaying in
                updateHighlight(for: newIndex, isPlaying: isPlaying)
            }
    }

    // Clears highlight when not playing or out of range; otherwise applies the cue's range.
    private func updateHighlight(for cueIndex: Int?, isPlaying: Bool) {
        guard isPlaying, let cueIndex, cueIndex < highlightRanges.count else {
            playbackHighlightRangeOverride = nil
            activePlaybackCueIndex = nil
            return
        }

        activePlaybackCueIndex = cueIndex
        playbackHighlightRangeOverride = highlightRanges[cueIndex]
    }
}
