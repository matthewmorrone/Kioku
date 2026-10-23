import SwiftUI
import UIKit

// A breakdown card's Japanese line: the card's own sentence while collapsed, one row per breakdown
// word while expanded, with the word's gloss beside its segments. Expanding swaps the sentence for
// segment pieces laid out the same way, then springs them into their rows; collapsing springs them
// back into the sentence layout and swaps the sentence in again once they land.
//
// Layout: the `sentence` view, or the pieces in a FlowLayout (spacing 0, segments touching like
// the packed renderer) or a SongLineSplitLayout (a word's segments side by side in its row, every
// gloss starting at one column on the segments' baseline). Each piece is a KiokuCoreTextRendererView
// sized to its footprint, the wider of its headword and its furigana; segments with no gloss to show
// fade out of the split.
struct SongLineSegmentsView<Sentence: View>: View {
    let isExpanded: Bool
    // The card's line, for the glosses' scroll ids (SongLineCard.wordRowID).
    let lineIndex: Int
    let pieces: [SongLineSegmentPiece]
    // The split's rows: which segments sit together and the words glossed beside them.
    let rows: [SongLineSegmentRow]
    let textSize: CGFloat
    let furiganaGap: Double
    // The part of the line Listen-along is reading, in line coordinates; the row holding it lights up.
    let playbackHighlightRange: NSRange?
    let onTap: () -> Void
    let onWordTapped: (SongWord) -> Void
    let sentence: () -> Sentence

    // The renderer's built-in side insets (RenderGeometry), cancelled per piece so neighbouring
    // segments touch instead of sitting 8pt apart.
    private static var rendererSideInset: CGFloat { 4 }
    private static var spring: Animation { .spring(response: 0.45, dampingFraction: 0.85) }

    @State private var phase: SongLineSegmentsPhase
    // Mirrors `isExpanded` in state so animation completions read the current value, not the
    // value captured when the animation started.
    @State private var wantsSplit: Bool

    // Starts in the resting phase for `isExpanded`, so a card scrolled back into view doesn't replay
    // the split.
    init(
        isExpanded: Bool,
        lineIndex: Int,
        pieces: [SongLineSegmentPiece],
        rows: [SongLineSegmentRow],
        textSize: CGFloat,
        furiganaGap: Double,
        playbackHighlightRange: NSRange?,
        onTap: @escaping () -> Void,
        onWordTapped: @escaping (SongWord) -> Void,
        @ViewBuilder sentence: @escaping () -> Sentence
    ) {
        self.isExpanded = isExpanded
        self.lineIndex = lineIndex
        self.pieces = pieces
        self.rows = rows
        self.textSize = textSize
        self.furiganaGap = furiganaGap
        self.playbackHighlightRange = playbackHighlightRange
        self.onTap = onTap
        self.onWordTapped = onWordTapped
        self.sentence = sentence
        _phase = State(initialValue: isExpanded ? .split : .sentence)
        _wantsSplit = State(initialValue: isExpanded)
    }

    var body: some View {
        Group {
            if phase == .sentence {
                sentence()
            } else {
                piecesLayout
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            wantsSplit = expanded
            if expanded {
                // From the sentence, mount the pieces first; they spring apart once laid out.
                if phase == .sentence {
                    phase = .flowing
                } else {
                    withAnimation(Self.spring) { phase = .split }
                }
            } else if phase != .sentence {
                withAnimation(Self.spring) {
                    phase = .flowing
                } completion: {
                    if wantsSplit == false { phase = .sentence }
                }
            }
        }
    }

    // The pieces in the current phase's layout. Mounting in `.flowing` springs them into the split
    // on the next turn of the run loop, after the flowing layout has been drawn once. Split, only the
    // segments in a row keep their place (punctuation, words the breakdown didn't list, and words the
    // visibility options hide drop out), and each row's glosses fade in beside it.
    private var piecesLayout: some View {
        let isSplit = phase == .split
        let layout = isSplit ? AnyLayout(SongLineSplitLayout()) : AnyLayout(FlowLayout(spacing: 0))
        let rowByLocation = Dictionary(
            rows.enumerated().flatMap { index, row in row.pieceLocations.map { ($0, index) } },
            uniquingKeysWith: { first, _ in first }
        )
        let shownPieces = isSplit ? pieces.filter { rowByLocation[$0.location] != nil } : pieces
        let glossIDs = glossScrollIDs()
        return layout {
            // Row bands first, so they draw behind the segments and glosses.
            if isSplit {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSpoken(row) ? Color.accentColor.opacity(0.16) : Color.clear)
                        // Reaches back over the leading inset so the band frames the segments evenly.
                        .padding(.leading, -Self.rendererSideInset)
                        .layoutValue(key: SongLineSplitSlotKey.self, value: SongLineSplitSlot(row: index, role: .background))
                }
            }
            ForEach(shownPieces) { piece in
                segmentView(piece, width: footprintWidth(of: piece.cache))
                    .layoutValue(key: SongLineSplitSlotKey.self,
                                 value: SongLineSplitSlot(row: rowByLocation[piece.location] ?? 0, role: .segment))
            }
            if isSplit {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    glosses(row.words, ids: glossIDs[index])
                        .layoutValue(key: SongLineSplitSlotKey.self, value: SongLineSplitSlot(row: index, role: .gloss))
                        .transition(.opacity)
                }
            }
        }
        // Starts the first segment where the collapsed sentence's renderer draws it.
        .padding(.leading, Self.rendererSideInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            guard phase == .flowing else { return }
            DispatchQueue.main.async {
                guard wantsSplit, phase == .flowing else { return }
                withAnimation(Self.spring) { phase = .split }
            }
        }
    }

    // Whether Listen-along is reading this row: the spoken range touches one of its segments.
    private func isSpoken(_ row: SongLineSegmentRow) -> Bool {
        guard let range = playbackHighlightRange else { return false }
        return pieces.contains { piece in
            row.pieceLocations.contains(piece.location)
                && NSIntersectionRange(range, NSRange(location: piece.location, length: (piece.cache.sourceText as NSString).length)).length > 0
        }
    }

    // Scroll ids for each row's glosses, in order: a surface's first gloss in the line gets the id
    // SongLineCard.wordRowID names, so the mini player can scroll to it; later repeats get a
    // positional id that can't collide with it.
    private func glossScrollIDs() -> [[String]] {
        var seen: Set<String> = []
        var ordinal = 0
        return rows.map { row in
            row.words.map { word in
                let surface = word.surface.trimmingCharacters(in: .whitespacesAndNewlines)
                ordinal += 1
                guard seen.insert(surface).inserted else { return "word-\(lineIndex)-#\(ordinal)" }
                return SongLineCard.wordRowID(lineIndex: lineIndex, surface: surface)
            }
        }
    }

    // One segment drawn through the shared CoreText renderer at the line's size, framed to its
    // footprint so the layouts can measure it (the renderer itself only fills a proposed width).
    private func segmentView(_ piece: SongLineSegmentPiece, width: CGFloat) -> some View {
        let cache = piece.cache
        return KiokuCoreTextRendererView(
            text: cache.sourceText,
            segmentationRanges: cache.segmentationRanges,
            furiganaBySegmentLocation: cache.furiganaBySegmentLocation,
            furiganaLengthBySegmentLocation: cache.furiganaLengthBySegmentLocation,
            isFuriganaVisible: true,
            isVisualEnhancementsEnabled: true,
            isColorAlternationEnabled: false,
            textSize: .constant(Double(textSize)),
            lineSpacing: 4,
            kerning: 0,
            furiganaGap: furiganaGap,
            evenSegmentColor: .label,
            oddSegmentColor: .label,
            isLineWrappingEnabled: false,
            isRubySpacingEnabled: true,
            selectedHighlightRange: nil,
            playbackHighlightRange: nil,
            selectionHighlightColor: .clear,
            playbackHighlightColor: .clear,
            unknownSegmentLocations: [],
            isHighlightUnknownEnabled: false,
            unknownSegmentColor: .label,
            debugFlags: KiokuDebugOverlayView.Flags(),
            illegalMergeLocation: nil,
            onSegmentTapped: { _, _, _ in onTap() },
            isScrollEnabled: false
        )
        .frame(width: width + 2 * Self.rendererSideInset)
        .padding(.horizontal, -Self.rendererSideInset)
    }

    // The glosses for one row's words, the first on the segments' baseline, each tagged with
    // its scroll id. Tapping one opens that word's lookup.
    private func glosses(_ words: [SongWord], ids: [String]) -> some View {
        let geometry = RenderGeometry.resolve(textSize: Double(textSize), userLineSpacing: 4, furiganaGap: furiganaGap)
        let glossFont = UIFont.preferredFont(forTextStyle: .callout)
        let baselineOffset = geometry.topInset + ReadingFont.body(size: textSize).ascender - glossFont.ascender
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(words.enumerated()), id: \.offset) { offset, word in
                Button {
                    onWordTapped(word)
                } label: {
                    Text(SongDefinitionCleaner.clean(word.definition))
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .id(offset < ids.count ? ids[offset] : "word-\(lineIndex)-\(word.surface)-\(offset)")
                .accessibilityHint("Look up \(word.surface)")
            }
        }
        .padding(.top, max(0, baselineOffset))
        .padding(.bottom, 8)
    }

    // The piece's drawn width: headword or furigana, whichever is wider (rounded up so the
    // renderer never clips its last glyph).
    private func footprintWidth(of cache: LineFuriganaCache) -> CGFloat {
        ceil(SongLineFitSize.naturalWidth(
            of: cache.sourceText,
            font: ReadingFont.body(size: textSize),
            rubyFont: UIFont.systemFont(ofSize: textSize * 0.5),
            segmentationRanges: cache.segmentationRanges,
            furiganaBySegmentLocation: cache.furiganaBySegmentLocation
        )) + 1
    }
}
