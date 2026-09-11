import SwiftUI

// Top action bar for the karaoke view: Re-align (one forced-alignment pass over the whole song)
// and the line/word highlight-granularity toggle. Not private: called from panel(geo:) in
// LyricsView.swift.
extension LyricsView {
    // Re-align button (or its live progress chip while a run is in flight) plus the granularity toggle.
    func reAlignBar() -> some View {
        HStack(spacing: 8) {
            if isReAligning {
                // Live progress is its OWN non-interactive chip, not the disabled Button's
                // label — a disabled Button dims its whole label, which made the status text
                // read as greyed-out/inactive. `.primary` keeps it high-contrast over the bar.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(reAlignMessage.isEmpty ? "Re-aligning…" : reAlignMessage)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .frame(height: 28)
                .background(Color.accentColor.opacity(0.16))
                .clipShape(Capsule())
                .accessibilityLabel(reAlignMessage.isEmpty ? "Re-aligning" : reAlignMessage)
            } else {
                Button {
                    onReAlign()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 12, weight: .semibold))
                        Text(cues.isEmpty ? "Align" : "Re-align")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 16)
                    .frame(height: 28)
                    .background(Color.accentColor.opacity(0.16))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(cues.isEmpty ? "Align all lyrics to the audio" : "Re-align all lyrics to the audio")
            }

            Spacer(minLength: 0)

            Button {
                let current = LyricsHighlightGranularity(rawValue: quickGranularityRaw) ?? .word
                let next: LyricsHighlightGranularity = current == .sentence ? .word : .sentence
                quickGranularityRaw = next.rawValue
            } label: {
                let isSentence = quickGranularityRaw == LyricsHighlightGranularity.sentence.rawValue
                HStack(spacing: 6) {
                    Image(systemName: isSentence ? "line.3.horizontal" : "textformat.abc")
                        .font(.system(size: 12, weight: .semibold))
                    Text(isSentence ? "Line" : "Word")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(isSentence ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background((isSentence ? Color.accentColor : Color.secondary).opacity(0.16))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(quickGranularityRaw == LyricsHighlightGranularity.sentence.rawValue
                ? "Highlighting by line. Tap to switch to word-by-word."
                : "Highlighting word-by-word. Tap to switch to whole-line.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.18))
    }
}
