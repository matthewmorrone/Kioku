import SwiftUI

// Sing mode's live microphone waveform, drawn under the lyrics card's heard line: a row of
// rounded bars, newest on the right, redrawn about 20 times a second from the mic buffer so the
// singer can see their voice being picked up. A single Canvas inside a TimelineView.
struct SingWaveformView: View {
    // Bar heights 0…1, oldest first.
    let levels: () -> [Float]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { _ in
            Canvas { context, size in
                let values = levels()
                guard values.isEmpty == false else { return }
                let slot = size.width / CGFloat(values.count)
                let barWidth = max(1.5, slot * 0.55)
                for (i, value) in values.enumerated() {
                    let height = max(barWidth, CGFloat(value) * size.height)
                    let rect = CGRect(x: CGFloat(i) * slot + (slot - barWidth) / 2, y: (size.height - height) / 2,
                                      width: barWidth, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(.accentColor.opacity(0.35 + 0.65 * Double(value))))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
