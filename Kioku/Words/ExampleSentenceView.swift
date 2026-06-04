import SwiftUI

// One example sentence in the word detail view, rendered to match the reference layout:
//   - furigana over kanji (when a segmenter + reading data are available)
//   - the target headword highlighted within the sentence
//   - a speaker button that pronounces the Japanese
//   - the English translation beneath
//
// Reuses the Read tab's resolver + renderer so the readings match the main reader exactly.
// Degrades gracefully: with no segmenter or empty reading data the furigana cache resolves
// empty and the sentence falls back to plain (still highlighted + speakable) text — the same
// "no readings → visual no-op" contract SongStepperView relies on.
struct ExampleSentenceView: View {
    let japanese: String
    let english: String
    // Candidate surfaces to highlight within the sentence (saved surface + the entry's
    // kanji/kana forms). First one found in the sentence wins; nil highlight when none match.
    let highlightSurfaces: [String]
    let segmenter: (any TextSegmenting)?
    let surfaceReadingData: SurfaceReadingDataMap
    let kanjiReadingFallback: KanjiReadingFallbackMap
    let textSize: Double
    let onSpeak: (String) -> Void

    @AppStorage(TypographySettings.furiganaGapKey) private var furiganaGap = TypographySettings.defaultFuriganaGap
    // Computed once per appearance; nil before the resolver has run for this sentence.
    @State private var cache: LineFuriganaCache?

    // UTF-16 range of the first highlight surface present in the sentence, for the renderer's
    // selected-highlight overlay (and the plain-text fallback's colored run).
    private var highlightRange: NSRange? {
        let ns = japanese as NSString
        for surface in highlightSurfaces where surface.isEmpty == false {
            let range = ns.range(of: surface)
            if range.location != NSNotFound { return range }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                sentenceView
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    onSpeak(japanese)
                } label: {
                    Image(systemName: "speaker.wave.2")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            Text(english)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .task(id: japanese) { computeCacheIfNeeded() }
    }

    @ViewBuilder
    private var sentenceView: some View {
        if let cache, cache.furiganaBySegmentLocation.isEmpty == false {
            // Furigana path — mirrors SongLineCard.furiganaRow, adding the target highlight
            // and sizing for an inline example rather than the 28pt song headline.
            FuriganaTextRenderer(
                isActive: true,
                isOverlayFrozen: false,
                text: japanese,
                isLineWrappingEnabled: true,
                segmentationRanges: cache.segmentationRanges,
                selectedSegmentLocation: nil,
                blankSelectedSegmentLocation: nil,
                selectedHighlightRangeOverride: highlightRange,
                playbackHighlightRangeOverride: nil,
                activePlaybackCueIndex: nil,
                illegalMergeBoundaryLocation: nil,
                furiganaBySegmentLocation: cache.furiganaBySegmentLocation,
                furiganaLengthBySegmentLocation: cache.furiganaLengthBySegmentLocation,
                isVisualEnhancementsEnabled: true,
                isRubySpacingEnabled: true,
                isColorAlternationEnabled: false,
                isHighlightUnknownEnabled: false,
                unknownSegmentLocations: [],
                changedSegmentLocations: [],
                changedReadingLocations: [],
                customEvenSegmentColorHex: "",
                customOddSegmentColorHex: "",
                debugFuriganaRects: false,
                debugHeadwordRects: false,
                debugHeadwordLineBands: false,
                debugFuriganaLineBands: false,
                debugBisectorHeadword: false,
                debugBisectorFurigana: false,
                debugEnvelopeRects: false,
                debugLeftInsetGuide: false,
                externalContentOffsetY: 0,
                onScrollOffsetYChanged: { _ in },
                onSegmentTapped: { _, _, _ in },
                textSize: .constant(textSize),
                lineSpacing: 4,
                kerning: 0,
                furiganaGap: furiganaGap,
                textAlignment: .natural,
                isScrollEnabled: false
            )
        } else {
            // Plain fallback — still highlights the target word so it reads like the reference
            // even when furigana data isn't in scope.
            Text(plainAttributed)
                .font(.system(size: textSize))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Plain-text rendering with the target surface tinted in the accent color.
    private var plainAttributed: AttributedString {
        var attributed = AttributedString(japanese)
        if let nsRange = highlightRange,
           let range = Range(nsRange, in: attributed) {
            attributed[range].foregroundColor = Color.accentColor
        }
        return attributed
    }

    // Segments the sentence and resolves per-segment readings via the Read tab's resolver,
    // exactly as SongStepperView does. Synchronous and cheap (preloaded reading map).
    private func computeCacheIfNeeded() {
        guard cache == nil else { return }
        guard let segmenter, japanese.isEmpty == false else {
            cache = LineFuriganaCache(segmentationRanges: [], furiganaBySegmentLocation: [:], furiganaLengthBySegmentLocation: [:])
            return
        }
        let edges = segmenter.longestMatchEdges(for: japanese)
        let resolved = FuriganaResolver(
            segmenter: segmenter,
            kanjiReadingFallback: kanjiReadingFallback
        ).build(
            for: japanese,
            edges: edges,
            surfaceReadingData: surfaceReadingData
        )
        cache = LineFuriganaCache(
            segmentationRanges: edges.map { $0.start..<$0.end },
            furiganaBySegmentLocation: resolved.byLocation,
            furiganaLengthBySegmentLocation: resolved.lengthByLocation
        )
    }
}
