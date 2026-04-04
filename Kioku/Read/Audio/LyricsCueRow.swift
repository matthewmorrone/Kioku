import SwiftUI
import Translation

// Renders one subtitle cue row inside the lyrics popup.
// The active row shows furigana for the full cue line, tappable word chips, and a translation.
// Inactive rows show plain text with opacity scaled by distance from the active cue.
struct LyricsCueRow: View {
    let cue: SubtitleCue
    let cueIndex: Int
    let isActive: Bool
    let distanceFromActive: Int
    let displayStyle: LyricsDisplayStyle
    let furiganaBySegmentLocation: [Int: String]
    let furiganaLengthBySegmentLocation: [Int: Int]
    let segmentationRanges: [Range<String.Index>]
    let noteText: String
    // The NSRange in noteText corresponding to this cue, nil if unresolved.
    let highlightRange: NSRange?
    let translationCache: LyricsTranslationCache
    let onSegmentTapped: (Int) -> Void
    let onCueTapped: () -> Void

    var body: some View {
        if isActive {
            activeCueRow
        } else {
            inactiveCueRow
        }
    }

    // Renders the highlighted active cue: full-line furigana, tappable word chips, translation.
    private var activeCueRow: some View {
        VStack(spacing: 8) {
            // Full cue rendered as one FuriganaLabel using the concatenated reading.
            // This avoids per-segment layout issues and keeps furigana above the correct kanji.
            if let (surface, reading) = fullCueSurfaceAndReading() {
                FuriganaLabel(
                    surface: surface,
                    reading: reading,
                    font: .systemFont(ofSize: 20, weight: .bold),
                    gap: 3
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            } else {
                Text(cue.text)
                    .font(.system(size: 20, weight: .bold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            // Tappable word chips — plain text, no furigana duplication.
            let segments = cueSegments()
            if segments.isEmpty == false {
                InlineWrapLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(segments, id: \.location) { segment in
                        Button {
                            onSegmentTapped(segment.location)
                        } label: {
                            Text(segment.surface)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color(.secondarySystemFill))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if let translation = translationCache.translations[cueIndex] {
                Text(translation)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .italic()
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(Color(.systemOrange).opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .translationTask(TranslationSession.Configuration(source: .init(identifier: "ja"), target: nil)) { session in
            translationCache.requestTranslation(cueIndex: cueIndex, text: cue.text, session: session)
        }
    }

    // Renders a faded inactive row. Tap seeks to that cue.
    private var inactiveCueRow: some View {
        Group {
            switch displayStyle {
            case .appleMusic:
                Text(cue.text)
                    .font(.system(size: 16))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            case .accentBar:
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color(.systemOrange).opacity(0))
                        .frame(width: 3)
                    Text(cue.text)
                        .font(.system(size: 16))
                        .padding(.leading, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .focusCard:
                Text(cue.text)
                    .font(.system(size: 14))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(Color.primary.opacity(distanceFromActive <= 1 ? 0.35 : 0.20))
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onCueTapped() }
    }

    // Builds the full surface string and concatenated reading for the cue's note text range.
    // Returns nil if the highlight range is unresolved or no furigana exists for this cue.
    private func fullCueSurfaceAndReading() -> (surface: String, reading: String)? {
        guard let highlightRange,
              let swiftRange = Range(highlightRange, in: noteText) else { return nil }
        let surface = String(noteText[swiftRange])

        // Collect all readings for segments within this range in order.
        let reading = segmentationRanges
            .compactMap { range -> String? in
                let nsRange = NSRange(range, in: noteText)
                guard NSIntersectionRange(nsRange, highlightRange).length > 0,
                      let reading = furiganaBySegmentLocation[nsRange.location],
                      reading.isEmpty == false else { return nil }
                return reading
            }
            .joined()

        guard surface.isEmpty == false else { return nil }
        // If no furigana found for this cue, return nil so we fall back to plain text.
        return reading.isEmpty ? nil : (surface: surface, reading: reading)
    }

    // Resolves the segments that fall within this cue's note text range.
    private func cueSegments() -> [(location: Int, surface: String)] {
        guard let highlightRange else { return [] }
        return segmentationRanges.compactMap { range in
            let nsRange = NSRange(range, in: noteText)
            guard NSIntersectionRange(nsRange, highlightRange).length > 0 else { return nil }
            let surface = String(noteText[range])
            // Skip whitespace-only segments.
            guard surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
            return (location: nsRange.location, surface: surface)
        }
    }
}
