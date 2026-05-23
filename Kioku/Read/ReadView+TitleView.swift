import SwiftUI

// Title header for ReadView: shows the resolved note title and hosts the per-note
// title-row quick actions (lyrics, extract-words, breakdown). The title is tappable
// to surface an edit alert backed by titleDraft.
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
                    titleDraft = resolvedTitle
                    isShowingTitleAlert = true
                }

            // Title-row quick actions for the currently-open note. The new-note + OCR
            // buttons moved to the Notes tab; this row now hosts the three per-note
            // actions: open the lyrics view, open the segment-list (extract words), and
            // open the LLM breakdown sheet for this note.
            HStack {
                Spacer()
                titleLyricsButton
                titleExtractWordsButton
                titleBreakdownButton
            }
        }
        .padding(.vertical, 8)
        .alert("Edit Title", isPresented: $isShowingTitleAlert) {
            TextField("Title", text: $titleDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                customTitle = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                flushPendingNotePersistenceIfNeeded()
            }
        }
    }
}
