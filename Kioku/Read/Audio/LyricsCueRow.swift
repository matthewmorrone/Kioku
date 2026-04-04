import SwiftUI
import Translation

// Renders one subtitle cue row inside the lyrics popup.
// The active row shows furigana, tappable words, and a translation.
// Inactive rows show plain text with opacity scaled by distance from the active cue.
struct LyricsCueRow: View {
    let cue: SubtitleCue
    let cueIndex: Int
    let isActive: Bool
    // Distance from the active cue index (0 = active, 1 = adjacent, 2+ = further away).
    let distanceFromActive: Int
    let displayStyle: LyricsDisplayStyle
    // Furigana data from ReadView — only used for the active row.
    let furiganaBySegmentLocation: [Int: String]
    let furiganaLengthBySegmentLocation: [Int: Int]
    let segmentationRanges: [Range<String.Index>]
    let noteText: String
    // The NSRange in noteText corresponding to this cue, nil if unresolved.
    let highlightRange: NSRange?
    let translationCache: LyricsTranslationCache
    // Called when a word segment in the active row is tapped.
    let onSegmentTapped: (Int) -> Void
    // Called when an inactive row is tapped — seeks to this cue.
    let onCueTapped: () -> Void

    var body: some View {
        if isActive {
            activeCueRow
        } else {
            inactiveCueRow
        }
    }

    // Renders the highlighted active cue with furigana, tappable words, and translation.
    private var activeCueRow: some View {
        VStack(spacing: 4) {
            wordsRow
            if let translation = translationCache.translations[cueIndex] {
                Text(translation)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .italic()
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(Color(.systemOrange).opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .translationTask(TranslationSession.Configuration(source: .init(identifier: "ja"), target: nil)) { session in
            translationCache.requestTranslation(cueIndex: cueIndex, text: cue.text, session: session)
        }
    }

    // Lays out tappable word buttons for segments within this cue's highlight range.
    @ViewBuilder
    private var wordsRow: some View {
        let segments = cueSegments()
        if segments.isEmpty {
            Text(cue.text)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
        } else {
            // Flow-wrap segments so long lines break naturally.
            InlineWrapLayout(spacing: 4, lineSpacing: 8) {
                ForEach(segments, id: \.location) { segment in
                    Button {
                        onSegmentTapped(segment.location)
                    } label: {
                        if let reading = furiganaBySegmentLocation[segment.location],
                           let length = furiganaLengthBySegmentLocation[segment.location],
                           length > 0,
                           let range = Range(NSRange(location: segment.location, length: length), in: noteText) {
                            let surface = String(noteText[range])
                            FuriganaLabel(
                                surface: surface,
                                reading: reading,
                                font: .systemFont(ofSize: 20),
                                gap: 2
                            )
                            .fixedSize(horizontal: true, vertical: true)
                        } else {
                            Text(segment.surface)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // Renders a faded, non-interactive cue row. Tap seeks to that cue.
    private var inactiveCueRow: some View {
        Group {
            switch displayStyle {
            case .appleMusic:
                Text(cue.text)
                    .font(.system(size: 15))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            case .accentBar:
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color(.systemOrange))
                        .frame(width: 2)
                        .opacity(0)  // invisible placeholder keeps layout stable; active accent shown only on active row
                    Text(cue.text)
                        .font(.system(size: 15))
                        .padding(.leading, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                }
            case .focusCard:
                Text(cue.text)
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
        }
        .foregroundStyle(Color.primary.opacity(distanceFromActive <= 1 ? 0.28 : 0.20))
        .contentShape(Rectangle())
        .onTapGesture { onCueTapped() }
    }

    // Resolves the segments that fall within this cue's note text range.
    private func cueSegments() -> [(location: Int, surface: String)] {
        guard let highlightRange else { return [] }
        return segmentationRanges.compactMap { range in
            let nsRange = NSRange(range, in: noteText)
            guard NSIntersectionRange(nsRange, highlightRange).length > 0 else { return nil }
            return (location: nsRange.location, surface: String(noteText[range]))
        }
    }
}
