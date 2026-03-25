import SwiftUI

// Renders the surface title with furigana and lemma subtitle for the segment lookup sheet header.
// Mirrors the header layout of WordDetailView exactly.
struct SegmentLookupSheetHeader: View {
    let surface: String
    let reading: String?
    let lemma: String?

    @AppStorage(TypographySettings.furiganaGapKey)
    private var furiganaGap = TypographySettings.defaultFuriganaGap

    var body: some View {
        VStack(spacing: 0) {
            let isPlaceholder = reading == "..."
            let hasFurigana = !isPlaceholder
                && ScriptClassifier.containsKanji(surface)
                && reading != nil
                && reading != surface

            if hasFurigana, let reading {
                FuriganaLabel(
                    surface: surface,
                    reading: reading,
                    font: .systemFont(ofSize: 34, weight: .bold),
                    gap: furiganaGap
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            } else if isPlaceholder {
                // Placeholder slot: show ... above the surface text in ruby position,
                // so it's visually clear the user can tap to enter a custom reading.
                VStack(spacing: 2) {
                    Text("...")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(surface)
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            } else {
                Text(surface)
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            if !isPlaceholder, let lemma, lemma != surface {
                Text(lemma)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .offset(y: hasFurigana ? -8 : 0)
            }
        }
        .padding(.horizontal, 20)
    }
}
