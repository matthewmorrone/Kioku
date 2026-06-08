import SwiftUI
import UIKit

// Inactive-cue row visuals — non-active SRT lines stacked above/below the active card, plus
// the ♪ separator for non-speech cues, distance-based scale/opacity fall-off, and the
// single-line scale fitter shared with the active card. Split out of LyricsView.swift so the
// main file focuses on the panel layout.
extension LyricsView {
    // Inactive cue row — plain text whose visual treatment depends on the selected lyrics style.
    // Apple Music: bold weight, leading-aligned, opacity fade with mild scale, no blur.
    // Accent Bar: center-aligned, scale + opacity + blur fall-off — the "karaoke depth" feel.
    // Single canonical inactive-cue row: centered text that scales, fades, and blurs further from
    // the active cue. Mismatch indicator (orange dot) survives because it conveys data, not style.
    @ViewBuilder
    func inactiveCueRow(index: Int, distance: Int) -> some View {
        let text = displayText(for: index)
        // When the "show ♪" toggle is off, non-speech (♪/♫) cues collapse to nothing so the
        // scroller shows only sung lines. EmptyView has zero height, so vocal rows pack
        // together with no gap where the marker used to be.
        if showMusicNotes == false && SubtitleParser.isNonSpeechCue(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            EmptyView()
        } else {
            let metrics = inactiveCueMetrics(distance: distance)
            let defaultSize = CGFloat(TypographySettings.defaultTextSize)
            let scaleFactor = distance == 0 ? scaleFactorForActiveCue(text: text, availableWidth: 280, defaultFontSize: defaultSize) : 1.0
            let fontSize = defaultSize * scaleFactor

            HStack(spacing: 4) {
                if hasMismatch(at: index) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                }
                Text(text)
                    .font(.system(size: fontSize, weight: .regular))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: inactiveCueRowHeight)
            .padding(.horizontal, 16)
            .scaleEffect(metrics.scale, anchor: .center)
            .opacity(metrics.opacity)
            .blur(radius: metrics.blur)
        }
    }

    // Whether the cue at `index` is a sung line rather than a ♪/♫ non-speech marker.
    func isVocalCue(at index: Int) -> Bool {
        guard cues.indices.contains(index) else { return false }
        let trimmed = cues[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SubtitleParser.isNonSpeechCue(trimmed) == false
    }

    // Nearest vocal cue to `index`: the index itself if it's vocal, else the next vocal cue
    // ahead, else the previous one, else the original index (all-instrumental edge case).
    // Used when the "show ♪" toggle is off so the active card and scroller split never land on
    // a hidden non-speech cue (which would otherwise blank the card during instrumental gaps).
    func nearestVocalCueIndex(from index: Int) -> Int {
        guard cues.indices.contains(index) else { return index }
        if isVocalCue(at: index) { return index }
        var forward = index + 1
        while forward < cues.count {
            if isVocalCue(at: forward) { return forward }
            forward += 1
        }
        var back = index - 1
        while back >= 0 {
            if isVocalCue(at: back) { return back }
            back -= 1
        }
        return index
    }

    // Apple Music-style fall-off: closer rows are larger and brighter, distant rows shrink
    // and fade. No blur — the size+opacity wave is the readable cue without softening text
    // into mush.
    func inactiveCueMetrics(distance: Int) -> (scale: Double, opacity: Double, blur: Double) {
        return (
            scale: max(0.62, 1.0 - Double(distance) * 0.10),
            opacity: max(0.28, 1.0 - Double(distance) * 0.16),
            blur: 0
        )
    }

    // Calculates the scale factor needed to fit the active cue on a single line without wrapping.
    // Measures the text at default size and scales down if necessary to fit within available width.
    func scaleFactorForActiveCue(text: String, availableWidth: CGFloat, defaultFontSize: CGFloat) -> CGFloat {
        let font = UIFont.systemFont(ofSize: defaultFontSize)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let requiredScale = min(1.0, availableWidth / textSize.width)
        // Clamp to reasonable bounds: don't go below 0.5x or above 1.0x
        return min(1.0, max(0.5, requiredScale))
    }
}
