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
        let metrics = inactiveCueMetrics(distance: distance)
        let defaultSize = CGFloat(TypographySettings.defaultTextSize)
        let text = displayText(for: index)
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

    // Renders a ♪ separator row inserted between vocal cues where the audio has a long
    // instrumental gap. Same height and distance-based scale/opacity as inactive cue rows so
    // the marker reads as a peer entry in the list rather than a compressed delimiter.
    @ViewBuilder
    func musicNoteSeparator(distance: Int) -> some View {
        let metrics = inactiveCueMetrics(distance: distance)
        Text("♪")
            .font(.system(size: CGFloat(TypographySettings.defaultTextSize), weight: .regular))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: inactiveCueRowHeight)
            .scaleEffect(metrics.scale, anchor: .center)
            .opacity(metrics.opacity)
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
