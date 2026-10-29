import SwiftUI

// The banner under the karaoke bar while the last alignment's issues are left: how many places
// the lyrics and the singing disagree, and Review, which opens their list (ReadView's
// LyricAlignmentIssueListView sheet). Not private: called from panel(geo:) in LyricsView.swift.
extension LyricsView {
    // The banner itself; nothing when there are no issues or an alignment is running.
    @ViewBuilder
    func alignmentIssuesBanner() -> some View {
        if alignmentIssueCount > 0, isReAligning == false {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.bubble")
                    .foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(alignmentIssueCount == 1
                         ? "1 place the lyrics don't match the singing"
                         : "\(alignmentIssueCount) places the lyrics don't match the singing")
                        .scaledFont(size: 12, weight: .semibold)
                    Text("Highlighting can be wrong or missing there until the note matches the song.")
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Review") { onReviewAlignmentIssues() }
                    .scaledFont(size: 12, weight: .semibold)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.orange.opacity(0.14))
        }
    }
}
