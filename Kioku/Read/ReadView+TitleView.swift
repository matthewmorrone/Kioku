import SwiftUI

// Title header for ReadView: shows the resolved note title and hosts the per-note
// title-row quick actions (lyrics, LLM correction, breakdown). The title is tappable
// to surface an edit alert backed by titleEdit.titleDraft.
extension ReadView {
    // Displays the editable note title at the top of the reading screen.
    var titleView: some View {
        VStack(spacing: 8) {
            Text(displayTitle)
                .font(.system(size: 24, weight: .bold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .onTapGesture {
                    titleEdit.titleDraft = resolvedTitle
                    titleEdit.isShowingTitleAlert = true
                }

            // Title-row quick actions for the currently-open note. The new-note + OCR
            // buttons moved to the Notes tab; the vocab list (extract words) moved down
            // to the bottom toolbar row; this row now hosts, in order: request/confirm
            // an LLM correction, open the LLM breakdown sheet, and open the lyrics view.
            // That last slot morphs into the minimized "now playing" control (ReadView+
            // MiniPlayer.swift) once playback has started and the full lyrics view is
            // dismissed — sharing lyricsMiniPlayerNamespace so the button visibly grows
            // into the play/pause + scrubber control in place, pushing the correction/
            // breakdown buttons left (never off-screen — the Spacer collapses first, and
            // the scrubber itself is what yields if the row still runs out of room).
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
                Spacer(minLength: 0)
                llmCorrectionButton
                titleBreakdownButton
                if isShowingLyricsMiniPlayer {
                    lyricsMiniPlayerInlineControl
                        .matchedGeometryEffect(id: "lyricsControl", in: lyricsMiniPlayerNamespace)
                } else {
                    titleLyricsButton
                        .matchedGeometryEffect(id: "lyricsControl", in: lyricsMiniPlayerNamespace)
                }
            }
            // dampingFraction close to 1 (near-critical damping): same settle time as before
            // (response is unchanged) but without the slight overshoot/wobble 0.8 gave the
            // morph between the button and the wider mini-player control — that overshoot read
            // as jitter rather than motion, especially with the two very different frame sizes
            // matchedGeometryEffect is interpolating between.
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
