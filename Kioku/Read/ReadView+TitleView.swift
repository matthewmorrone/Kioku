import SwiftUI

// Title header for ReadView: shows the resolved note title and hosts the per-note
// title-row quick actions (shuffle, breakdown, lyrics). The title is tappable
// to surface an edit alert backed by titleEdit.titleDraft.
extension ReadView {
    // Displays the editable note title at the top of the reading screen.
    var titleView: some View {
        VStack(spacing: 8) {
            Text(displayTitle)
                .scaledFont(size: 24, weight: .bold)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .onTapGesture {
                    titleEdit.titleDraft = resolvedTitle
                    titleEdit.isShowingTitleAlert = true
                }

            // Title-row quick actions, in order: open a random note, open the
            // breakdown sheet and open the lyrics view.
            // Once playback has started and the full lyrics view is dismissed, the minimized
            // "now playing" control (ReadView+MiniPlayer.swift) fills the row's empty leading
            // space. The buttons keep fixed trailing slots, so the control appearing or
            // disappearing never shifts them; the scrubber is what yields if room runs out.
            HStack {
                // A word tapped before dictionary resources finish loading (see
                // handleReadModeSegmentTap's readResourcesReady guard) highlights immediately
                // but its lookup is queued — this spinner is the only feedback that anything
                // is happening during that wait, which can run several seconds on first launch.
                if segmentSelection.pendingSegmentTapAfterResourcesReady != nil {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.7)
                        .accessibilityLabel("Loading dictionary")
                }
                if isShowingLyricsMiniPlayer {
                    lyricsMiniPlayerInlineControl
                        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .trailing)))
                } else {
                    Spacer(minLength: 0)
                }
                titleShuffleButton
                titleBreakdownButton
                    .tourTarget(.readBreakdown)
                titleLyricsButton
                    .tourTarget(.readLyrics)
            }
            // Near-critical damping: the control settles without the overshoot that reads as jitter.
            .animation(.spring(response: 0.4, dampingFraction: 0.95), value: isShowingLyricsMiniPlayer)
        }
        .padding(.vertical, 8)
        .alert("Edit Title", isPresented: $titleEdit.isShowingTitleAlert) {
            TextField("Title", text: $titleEdit.titleDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                titleEdit.customTitle = titleEdit.titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                flushPendingNotePersistenceIfNeeded()
            }
        }
    }
}
