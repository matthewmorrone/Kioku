import SwiftUI
import Translation

// Persistent FuriganaTextRenderer overlay for the active lyrics cue.
// Lives in LyricsView above the scroll list — never torn down between cue transitions
// so the UITextView instance persists and furigana renders without a recreation delay.
// Positioned at the vertical center of the cue list area to sit over the active row placeholder.
struct LyricsActiveCueOverlay: View {
    let activeCueIndex: Int?
    let cues: [SubtitleCue]
    let highlightRanges: [NSRange?]
    let furiganaBySegmentLocation: [Int: String]
    let furiganaLengthBySegmentLocation: [Int: Int]
    let segmentationRanges: [Range<String.Index>]
    let noteText: String
    @ObservedObject var translationCache: LyricsTranslationCache
    let panelWidth: CGFloat
    let onSegmentTapped: (Int) -> Void

    @AppStorage(TypographySettings.textSizeKey) private var textSize = TypographySettings.defaultTextSize
    @AppStorage(TypographySettings.furiganaGapKey) private var furiganaGap = TypographySettings.defaultFuriganaGap

    // Holds the translation session once prepared so it can be reused across cues.
    @State private var translationSession: TranslationSession? = nil

    var body: some View {
        if let index = activeCueIndex, cues.indices.contains(index) {
            let cue = cues[index]
            VStack(spacing: 8) {
                rendererView(cue: cue, cueIndex: index)
                if let translation = translationCache.translations[index] {
                    Text(translation)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .italic()
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 10)
            .frame(width: panelWidth - 32) // 16px horizontal padding each side from cueList
            .background(Color(.systemOrange).opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .onTapGesture {
                // Tapping the active cue row with no segment taps is a no-op.
            }
            // Seed the session on first appearance; translate whenever the active cue changes.
            .translationTask(translationConfig) { session in
                translationSession = session
                await translateCurrent(session: session, index: index, text: cue.text)
            }
            .onChange(of: activeCueIndex) { _, newIndex in
                guard let newIndex, newIndex < cues.count,
                      let session = translationSession else { return }
                let text = cues[newIndex].text
                Task { await translateCurrent(session: session, index: newIndex, text: text) }
            }
        }
    }

    // Translates a single cue using an already-prepared session.
    // Skips cues that are already cached.
    private func translateCurrent(session: TranslationSession, index: Int, text: String) async {
        guard translationCache.needsTranslation(cueIndex: index, text: text) else { return }
        do {
            try await session.prepareTranslation()
            let response = try await session.translate(text)
            await MainActor.run { translationCache.store(cueIndex: index, result: response.targetText) }
        } catch {
            // Failures are silent — the translation row simply won't appear.
        }
    }

    // Full cue as one FuriganaTextRenderer so segment taps use the same UITextView hit-testing
    // pipeline as the read tab. Scroll is disabled — the cue is always a single line.
    @ViewBuilder
    private func rendererView(cue: SubtitleCue, cueIndex: Int) -> some View {
        if let (surface, localSegRanges, localFurigana, localFuriganaLength) = cueData(cueIndex: cueIndex) {
            FuriganaTextRenderer(
                isActive: true,
                isOverlayFrozen: false,
                text: surface,
                isLineWrappingEnabled: true,
                segmentationRanges: localSegRanges,
                selectedSegmentLocation: nil,
                blankSelectedSegmentLocation: nil,
                selectedHighlightRangeOverride: nil,
                playbackHighlightRangeOverride: nil,
                activePlaybackCueIndex: nil,
                illegalMergeBoundaryLocation: nil,
                furiganaBySegmentLocation: localFurigana,
                furiganaLengthBySegmentLocation: localFuriganaLength,
                isVisualEnhancementsEnabled: true,
                isColorAlternationEnabled: true,
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
                externalContentOffsetY: 0,
                onScrollOffsetYChanged: { _ in },
                onSegmentTapped: { location, _, _ in
                    guard let location else { return }
                    onSegmentTapped(location)
                },
                textSize: Binding(get: { textSize }, set: { _ in }),
                lineSpacing: 0,
                kerning: 0,
                furiganaGap: furiganaGap,
                textAlignment: .center,
                isScrollEnabled: false
            )
            .frame(maxWidth: .infinity)
        } else {
            Text(cue.text)
                .font(.system(size: CGFloat(textSize)))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // Explicit source→target config so the Translation framework always has a concrete target locale.
    private var translationConfig: TranslationSession.Configuration {
        let target = Locale.preferredLanguages
            .first(where: { !$0.hasPrefix("ja") })
            .map { Locale.Language(identifier: $0) }
            ?? Locale.Language(identifier: "en-US")
        return TranslationSession.Configuration(
            source: Locale.Language(identifier: "ja"),
            target: target
        )
    }

    // Builds the surface string and surface-local data for FuriganaTextRenderer.
    // Furigana keys and segmentation ranges are shifted to be offsets into surface, not noteText.
    private func cueData(cueIndex: Int) -> (surface: String, segRanges: [Range<String.Index>], furigana: [Int: String], furiganaLength: [Int: Int])? {
        guard cueIndex < highlightRanges.count,
              let highlightRange = highlightRanges[cueIndex],
              let swiftRange = Range(highlightRange, in: noteText) else { return nil }
        let surface = String(noteText[swiftRange])
        guard surface.isEmpty == false else { return nil }

        let surfaceBase = highlightRange.location
        var localSegRanges: [Range<String.Index>] = []
        var localFurigana: [Int: String] = [:]
        var localFuriganaLength: [Int: Int] = [:]

        for segRange in segmentationRanges {
            let nsRange = NSRange(segRange, in: noteText)
            guard NSIntersectionRange(nsRange, highlightRange).length > 0 else { continue }
            let localOffset = nsRange.location - surfaceBase
            if let localRange = Range(NSRange(location: localOffset, length: nsRange.length), in: surface) {
                localSegRanges.append(localRange)
            }
        }

        // Copy all furigana entries whose key falls within the highlight range, shifting to surface offsets.
        // Furigana keys may be sub-run locations inside a segment, not necessarily segment start locations,
        // so a per-segment lookup by nsRange.location misses them.
        for (location, reading) in furiganaBySegmentLocation {
            guard location >= highlightRange.location,
                  location < highlightRange.location + highlightRange.length else { continue }
            localFurigana[location - surfaceBase] = reading
        }
        for (location, length) in furiganaLengthBySegmentLocation {
            guard location >= highlightRange.location,
                  location < highlightRange.location + highlightRange.length else { continue }
            localFuriganaLength[location - surfaceBase] = length
        }

        return (surface: surface, segRanges: localSegRanges, furigana: localFurigana, furiganaLength: localFuriganaLength)
    }
}
