import SwiftUI

// Renders a song's target vocabulary as wrapping pill-shaped chips.
// Falls back to a non-wrapping HStack on iOS 15 where the custom Layout isn't available.
// Major sections: chip flow (iOS 16+) or single-row prefix (iOS 15).
struct SongJourneyVocabChips: View {
    let items: [String]

    var body: some View {
        if #available(iOS 16.0, *) {
            SongJourneyChipFlowLayout(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    chip(item)
                }
            }
        } else {
            HStack(spacing: 6) {
                ForEach(Array(items.prefix(6).enumerated()), id: \.offset) { _, item in
                    chip(item)
                }
            }
        }
    }

    // Builds one chip styled to match the secondary controls used elsewhere in the journey.
    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(.tertiarySystemFill)))
            .foregroundStyle(.primary)
    }
}
