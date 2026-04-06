import SwiftUI
import UIKit
import Translation

// Renders one subtitle cue row inside the lyrics popup.
// Active row: a single full-line FuriganaLabel with per-segment colors, scaled to fit without wrapping.
// Inactive rows: plain text scaled and faded by distance from the active cue.
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
    let highlightRange: NSRange?
    // Per-segment foreground colors keyed by UTF-16 location in noteText.
    let segmentColorByLocation: [Int: UIColor]
    let translationCache: LyricsTranslationCache
    let onSegmentTapped: (Int) -> Void
    let onCueTapped: () -> Void

    @AppStorage(TypographySettings.textSizeKey) private var textSize = TypographySettings.defaultTextSize
    @AppStorage(TypographySettings.furiganaGapKey) private var furiganaGap = TypographySettings.defaultFuriganaGap

    private var rowOpacity: Double {
        switch distanceFromActive {
        case 0: return 1.0
        case 1: return 0.50
        case 2: return 0.30
        default: return 0.18
        }
    }

    private var inactiveFontSize: CGFloat {
        switch distanceFromActive {
            case 1:  return 17
            case 2:  return 15
            default: return 13
        }
    }

    private var verticalPadding: CGFloat {
        switch distanceFromActive {
            case 1:  return 10
            case 2:  return 6
            default: return 4
        }
    }

    var body: some View {
        if isActive { activeCueRow } else { inactiveCueRow }
    }

    private var activeCueRow: some View {
        VStack(spacing: 8) {
            fullLineView
            if let translation = translationCache.translations[cueIndex] {
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
        .frame(maxWidth: .infinity)
        .background(Color(.systemOrange).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture {
            // Tapping the active cue row with no segment taps is a no-op — tapping a segment
            // requires knowing which one was tapped, which needs hit-testing inside FuriganaView.
        }
        .translationTask(TranslationSession.Configuration(source: .init(identifier: "ja"), target: nil)) { session in
            // Translate directly in this closure — session must not escape it.
            // .translationTask may re-fire on re-render; the needsTranslation guard makes it idempotent.
            guard translationCache.needsTranslation(cueIndex: cueIndex, text: cue.text) else { return }
            do {
                let response = try await session.translate(cue.text)
                await MainActor.run { translationCache.store(cueIndex: cueIndex, result: response.targetText) }
            } catch {
                // Failures are silent — the translation row simply won't appear.
            }
        }
    }

    // Full cue as one FuriganaLabel with per-segment colors, constrained to the available width.
    // FuriganaLabel.sizeThatFits reports the correct height (base text + furigana headroom) for
    // any given width, so SwiftUI allocates the right vertical space without manual scaling tricks.
    @ViewBuilder
    private var fullLineView: some View {
        let uiFont = UIFont.systemFont(ofSize: CGFloat(textSize))
        let gap = CGFloat(furiganaGap)

        if let (surface, reading, localColors) = fullCueData() {
            FuriganaLabel(
                surface: surface,
                reading: reading,
                font: uiFont,
                gap: gap,
                segmentColors: localColors
            )
            .frame(maxWidth: .infinity)
        } else {
            Text(cue.text)
                .font(Font(uiFont))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // Inactive row: plain text, faded and scaled by distance.
    private var inactiveCueRow: some View {
        Text(cue.text)
            .font(.system(size: inactiveFontSize, weight: distanceFromActive == 1 ? .medium : .regular))
            .multilineTextAlignment(.center)
            .foregroundStyle(Color.primary.opacity(rowOpacity))
            .frame(maxWidth: .infinity)
            .padding(.vertical, verticalPadding)
            .contentShape(Rectangle())
            .onTapGesture { onCueTapped() }
    }

    // Builds the surface, concatenated reading, and surface-local segment color map for the full cue.
    // Returns nil if the cue has no resolved range or empty surface.
    private func fullCueData() -> (surface: String, reading: String, localColors: [Int: UIColor])? {
        guard let highlightRange,
              let swiftRange = Range(highlightRange, in: noteText) else { return nil }
        let surface = String(noteText[swiftRange])
        guard surface.isEmpty == false else { return nil }

        // The surface starts at highlightRange.location in noteText.
        // Remap noteText-relative segment locations to surface-local UTF-16 offsets.
        let surfaceBase = highlightRange.location
        var reading = ""
        var localColors: [Int: UIColor] = [:]

        // Build the full kana reading of the surface by walking segments in order.
        // Each segment contributes either its furigana (if it has one) or its own surface text.
        // This produces a full phonetic reading that FuriganaView can align against kanji runs.
        var fullReading = ""
        for segRange in segmentationRanges {
            let nsRange = NSRange(segRange, in: noteText)
            guard NSIntersectionRange(nsRange, highlightRange).length > 0 else { continue }

            let localOffset = nsRange.location - surfaceBase
            let segSurface = String(noteText[segRange])

            if let color = segmentColorByLocation[nsRange.location] {
                for offset in 0..<nsRange.length {
                    localColors[localOffset + offset] = color
                }
            }

            if let r = furiganaBySegmentLocation[nsRange.location], r.isEmpty == false {
                fullReading += r
            } else {
                fullReading += segSurface
            }
        }
        reading = fullReading

        return (surface: surface, reading: reading, localColors: localColors)
    }
}
