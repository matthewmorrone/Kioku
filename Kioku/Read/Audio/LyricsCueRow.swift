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
            // Tapping the active cue row with no segment taps is a no-op — tapping a segment requires knowing which one was tapped, which needs hit-testing inside FuriganaView.
        }
        .translationTask(translationConfig) { session in
            // Translate directly in this closure — session must not escape it.
            // .translationTask may re-fire on re-render; the needsTranslation guard makes it idempotent.
            guard translationCache.needsTranslation(cueIndex: cueIndex, text: cue.text) else { return }
            do {
                // prepareTranslation prompts the user to download the language pack if not present.
                try await session.prepareTranslation()
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

        if let (surface, reading, localColors, runReadings) = fullCueData() {
            FuriganaLabel(
                surface: surface,
                reading: reading,
                font: uiFont,
                gap: gap,
                segmentColors: localColors,
                explicitRunReadings: runReadings
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


    // Explicit source→target config so the Translation framework always has a concrete target locale.
    // Falls back to en-US when the device has no preferred language distinct from Japanese.
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

    // Builds the surface, concatenated reading, surface-local segment colors, and explicit per-run readings for the full cue. Returns nil if the cue has no resolved range or empty surface.
    private func fullCueData() -> (surface: String, reading: String, localColors: [Int: UIColor], runReadings: [Int: String])? {
        guard let highlightRange,
              let swiftRange = Range(highlightRange, in: noteText) else { return nil }
        let surface = String(noteText[swiftRange])
        guard surface.isEmpty == false else { return nil }

        let surfaceBase = highlightRange.location
        var localColors: [Int: UIColor] = [:]
        var fullReading = ""
        // Per-kanji-run readings keyed by character index within `surface`.
        // Built by tracking how many Swift characters we've accumulated in the surface so far.
        var runReadings: [Int: String] = [:]
        var surfaceCharCursor = 0

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
                // Map this segment's character start in the surface to its furigana reading.
                // Only kanji segments have furigana, so this correctly keys kanji run starts.
                runReadings[surfaceCharCursor] = r
            } else {
                fullReading += segSurface
            }

            surfaceCharCursor += segSurface.count
        }

        return (surface: surface, reading: fullReading, localColors: localColors, runReadings: runReadings)
    }
}
