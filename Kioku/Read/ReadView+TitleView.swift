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
            HStack {
                // A word tapped before dictionary resources finish loading (see
                // handleReadModeSegmentTap's readResourcesReady guard) highlights immediately
                // but its lookup is queued — this spinner is the only feedback that anything
                // is happening during that wait, which can run several seconds on first launch.
                if pendingSegmentTapAfterResourcesReady != nil {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.7)
                        .accessibilityLabel("Loading dictionary")
                }
                Spacer()
                llmCorrectionButton
                titleBreakdownButton
                titleLyricsButton
            }
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
