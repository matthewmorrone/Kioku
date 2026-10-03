import SwiftUI

// The lyrics view's stand-in for a note with no timing yet: the note's lines as plain, dimmed
// text, so opening the lyrics while alignment runs shows the song rather than an empty card.
extension LyricsView {
    // Renders the note's non-blank lines in a scrollable, centered column.
    var unalignedLines: some View {
        let lines = noteText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }
        return ScrollView {
            VStack(spacing: 12) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .scaledFont(size: 17)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
    }
}
