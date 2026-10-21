import SwiftUI
import UIKit

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

    // Height of the ruby band above the first text line when furigana is rendered, so the
    // leading speaker button can align with the first HEADWORD line instead of the ruby.
    // Zero on the plain-text fallback path.
    private var speakerTopInset: CGFloat {
        guard let cache, cache.furiganaBySegmentLocation.isEmpty == false else { return 0 }
        let rubyFont = UIFont.systemFont(ofSize: textSize * TypographySettings.furiganaSizeFactor)
        return ceil(rubyFont.lineHeight) + CGFloat(furiganaGap)
    }

    // The sentence as the speaker should say it: every kanji run replaced by the furigana shown over
    // it. The synthesizer guesses kanji readings on its own and can pick a different one than the
    // ruby (銀杏 read いちょう under ぎんなん), so speaking the shown readings keeps ear and eye in
    // agreement. The plain sentence when no furigana has resolved.
    private var spokenText: String {
        guard let cache, cache.furiganaBySegmentLocation.isEmpty == false else { return japanese }
        let spoken = NSMutableString(string: japanese)
        // Back to front so earlier UTF-16 locations stay valid while later runs are replaced.
        for location in cache.furiganaBySegmentLocation.keys.sorted(by: >) {
            guard let reading = cache.furiganaBySegmentLocation[location],
                  let length = cache.furiganaLengthBySegmentLocation[location],
                  location + length <= spoken.length else { continue }
            spoken.replaceCharacters(in: NSRange(location: location, length: length), with: reading)
        }
        return spoken as String
    }

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
            // Speaker leads the row so the play affordance is in a consistent spot for every
            // example, instead of ragged-right after sentences of varying width.
            HStack(alignment: .top, spacing: 8) {
                Button {
                    onSpeak(spokenText)
                } label: {
                    Image(systemName: "speaker.wave.2")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                // The furigana path reserves a ruby band above the first text line; drop the
                // speaker by that band so it aligns with the headword line, not the ruby.
                .padding(.top, speakerTopInset)
                sentenceView
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(english)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .task(id: japanese) {
            // The cache is kept, so it must not be built against the empty launch-time segmenter.
            await segmenter?.waitUntilLoaded()
            computeCacheIfNeeded()
        }
    }

    @ViewBuilder
    private var sentenceView: some View {
        if let cache, cache.furiganaBySegmentLocation.isEmpty == false {
            // Furigana path — mirrors SongLineCard.furiganaRow, adding the target highlight
            // and sizing for an inline example rather than the 28pt song headline.
            KiokuCoreTextRendererView(
                text: japanese,
                segmentationRanges: cache.segmentationRanges,
                furiganaBySegmentLocation: cache.furiganaBySegmentLocation,
                furiganaLengthBySegmentLocation: cache.furiganaLengthBySegmentLocation,
                isFuriganaVisible: true,
                isVisualEnhancementsEnabled: true,
                isColorAlternationEnabled: false,
                textSize: .constant(textSize),
                lineSpacing: 4,
                kerning: 0,
                furiganaGap: furiganaGap,
                evenSegmentColor: .label,
                oddSegmentColor: .label,
                isLineWrappingEnabled: true,
                isRubySpacingEnabled: true,
                selectedHighlightRange: nil,
                playbackHighlightRange: nil,
                selectionHighlightColor: .clear,
                playbackHighlightColor: .clear,
                unknownSegmentLocations: [],
                isHighlightUnknownEnabled: false,
                unknownSegmentColor: .label,
                // Accent TEXT for the target word, not a highlight band — matches the plain
                // fallback's accent-colored run.
                accentTextRange: highlightRange,
                accentTextColor: .init(Color.accentColor),
                debugFlags: KiokuDebugOverlayView.Flags(),
                illegalMergeLocation: nil,
                onSegmentTapped: { _, _, _ in },
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
            cache = LineFuriganaCache(
                sourceText: japanese,
                segmentationRanges: [],
                furiganaBySegmentLocation: [:],
                furiganaLengthBySegmentLocation: [:]
            )
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
        let split = splitRubyAtHighlight(byLocation: resolved.byLocation, lengthByLocation: resolved.lengthByLocation)
        cache = LineFuriganaCache(
            sourceText: japanese,
            segmentationRanges: edges.map { $0.start..<$0.end },
            furiganaBySegmentLocation: split.byLocation,
            furiganaLengthBySegmentLocation: split.lengthByLocation
        )
    }

    // Splits a compound's ruby where the highlighted word ends inside it (化石 in 化石燃料), so the
    // accent colour covers only the reading of the highlighted kanji (かせき) and the rest of the
    // compound (ねんりょう) keeps the sentence colour. The split needs the highlighted word's own
    // dictionary reading to start (or end) the compound's reading; a compound that voices or
    // otherwise changes it keeps its single ruby rather than guess where to cut.
    private func splitRubyAtHighlight(
        byLocation: [Int: String],
        lengthByLocation: [Int: Int]
    ) -> (byLocation: [Int: String], lengthByLocation: [Int: Int]) {
        guard let accent = highlightRange else { return (byLocation, lengthByLocation) }
        let surface = (japanese as NSString).substring(with: accent)
        guard let listed = FuriganaResolver.listedReadings(surface, surfaceReadingData: surfaceReadingData) else {
            return (byLocation, lengthByLocation)
        }
        let readings = listed.map(KanaNormalizer.katakanaToHiragana)
        var newByLocation = byLocation
        var newLengthByLocation = lengthByLocation
        for (location, reading) in byLocation {
            guard let length = lengthByLocation[location],
                  accent.length < length,
                  accent.location >= location,
                  accent.upperBound <= location + length else { continue }
            let compound = KanaNormalizer.katakanaToHiragana(reading)
            if accent.location == location,
               let head = readings.first(where: { compound.hasPrefix($0) && compound.count > $0.count }) {
                newByLocation[location] = head
                newLengthByLocation[location] = accent.length
                newByLocation[accent.upperBound] = String(compound.dropFirst(head.count))
                newLengthByLocation[accent.upperBound] = length - accent.length
            } else if accent.upperBound == location + length,
                      let tail = readings.first(where: { compound.hasSuffix($0) && compound.count > $0.count }) {
                newByLocation[location] = String(compound.dropLast(tail.count))
                newLengthByLocation[location] = length - accent.length
                newByLocation[accent.location] = tail
                newLengthByLocation[accent.location] = accent.length
            }
        }
        return (newByLocation, newLengthByLocation)
    }
}
