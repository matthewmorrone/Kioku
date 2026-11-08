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
    // The readings the word being shown has (its kana forms). A sentence whose highlighted word is
    // read otherwise (5日 as にち or にっかん under いつか) is another word's example, so it is hidden.
    // Empty means no such check.
    var acceptedReadings: [String] = []
    let segmenter: (any TextSegmenting)?
    let surfaceReadingData: SurfaceReadingDataMap
    let kanjiReadingFallback: KanjiReadingFallbackMap
    let textSize: Double
    let onSpeak: (String) -> Void
    // Called with the surface of a tapped word so the host can open its dictionary entry. Nil keeps
    // the sentence's words inert.
    var onOpenWord: ((String) -> Void)? = nil
    // Whether a segment's surface has a dictionary entry; those segments (other than the highlighted
    // word) are underlined to show they open. Nil underlines nothing.
    var hasEntry: ((String) -> Bool)? = nil

    @AppStorage(TypographySettings.furiganaGapKey) private var furiganaGap = TypographySettings.defaultFuriganaGap
    // Computed once per appearance; nil before the resolver has run for this sentence.
    @State private var cache: LineFuriganaCache?
    // UTF-16 ranges of the segments that open an entry, resolved once alongside the cache.
    @State private var underlinedRanges: [NSRange] = []

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
        // A sentence spelling the number in digits (5日) still holds the kanji-numeral headword (五日).
        for surface in highlightSurfaces {
            guard let digitForm = KanjiNumeralDigits.digitForm(of: surface) else { continue }
            let range = ns.range(of: digitForm)
            if range.location != NSNotFound { return range }
        }
        return nil
    }

    // True once the furigana has resolved and the ruby over the highlighted word spells none of the
    // accepted readings. A run reaching past the highlight (七十五日 read しちじゅうごにち holds 五日)
    // counts whole, so it matches only when it contains an accepted reading. Kana highlights carry no
    // ruby, so they never mismatch.
    private var isReadingMismatch: Bool {
        guard acceptedReadings.isEmpty == false, let cache, let range = highlightRange else { return false }
        let ruby = cache.furiganaBySegmentLocation
            .filter { location, _ in
                let length = cache.furiganaLengthBySegmentLocation[location] ?? 1
                return location < range.location + range.length && location + length > range.location
            }
            .sorted { $0.key < $1.key }
            .map(\.value)
            .joined()
        guard ruby.isEmpty == false else { return false }
        let shown = KanaNormalizer.katakanaToHiragana(ruby)
        return acceptedReadings.map(KanaNormalizer.katakanaToHiragana).contains { shown.contains($0) } == false
    }

    // True when a kana highlight sits inside a longer word of the sentence (よ inside よる, の inside
    // のんびり): that sentence is an example of the longer word, not of the one being shown. Kanji
    // highlights are left to the reading check above.
    private var isHighlightInsideLongerWord: Bool {
        guard let cache, let range = highlightRange,
              ScriptClassifier.isPureKana((japanese as NSString).substring(with: range)) else { return false }
        return cache.segmentationRanges.contains { segment in
            let segmentRange = NSRange(segment, in: japanese)
            return NSIntersectionRange(segmentRange, range).length > 0 && segmentRange.length > range.length
        }
    }

    var body: some View {
        Group {
            if isReadingMismatch == false && isHighlightInsideLongerWord == false {
                rowContent
            }
        }
        .task(id: japanese) {
            // The cache is kept, so it must not be built against the empty launch-time segmenter.
            await segmenter?.waitUntilLoaded()
            computeCacheIfNeeded()
        }
    }

    // The sentence row itself: speaker, furigana'd text, translation.
    private var rowContent: some View {
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
                underlinedRanges: underlinedRanges,
                debugFlags: KiokuDebugOverlayView.Flags(),
                illegalMergeLocation: nil,
                onSegmentTapped: { location, _, _ in openWord(at: location, in: cache) },
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

    // Hands the tapped segment's surface to the host, which resolves it to a dictionary entry. The
    // renderer reports the segment's UTF-16 location; taps outside any segment do nothing.
    private func openWord(at location: Int?, in cache: LineFuriganaCache) {
        guard let onOpenWord, let location else { return }
        let match = cache.segmentationRanges.first { range in
            NSRange(range, in: japanese).contains(location)
        }
        guard let match else { return }
        let surface = String(japanese[match])
        onOpenWord(surface)
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
        let ranges = edges.map { $0.start..<$0.end }
        underlinedRanges = entryBackedRanges(in: ranges)
        cache = LineFuriganaCache(
            sourceText: japanese,
            segmentationRanges: ranges,
            furiganaBySegmentLocation: split.byLocation,
            furiganaLengthBySegmentLocation: split.lengthByLocation
        )
    }

    // The segments whose surface has a dictionary entry, minus any touching the highlighted subject
    // word (already accent-colored), as UTF-16 ranges for the underline.
    private func entryBackedRanges(in segments: [Range<String.Index>]) -> [NSRange] {
        guard let hasEntry else { return [] }
        let subject = highlightRange
        return segments.compactMap { segment in
            let range = NSRange(segment, in: japanese)
            if let subject, NSIntersectionRange(range, subject).length > 0 { return nil }
            return hasEntry(String(japanese[segment])) ? range : nil
        }
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
