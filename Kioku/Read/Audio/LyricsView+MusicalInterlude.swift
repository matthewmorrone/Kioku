import SwiftUI

// Non-speech (♪) cue display: a row of note glyphs scaled to the interlude's duration — a
// four-second gap and a three-minute instrumental break both used to render as the exact same
// single "♪", giving no sense of how long the wait is. The active card additionally pulses the
// notes in sequence while that cue is the one actually playing, as a "still going" signal.
// Persisted cue text itself is untouched (still a plain "♪" — SubtitleParser.isNonSpeechCue
// keeps working on it); this is a display-time expansion in both the active card and the
// scrolling rows.
extension LyricsView {
    // Whether the cue at `index` is a non-speech (♪) marker rather than a sung line.
    func isNonSpeechCue(at index: Int) -> Bool {
        guard index >= 0, index < cues.count else { return false }
        return SubtitleParser.isNonSpeechCue(cues[index].text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // One note per ~4s of gap, clamped so a multi-minute intro/outro doesn't overrun the card.
    static func interludeNoteCount(durationMs: Int) -> Int {
        max(1, min(6, Int((Double(durationMs) / 4000.0).rounded(.up))))
    }

    // Space-separated note glyphs for the scrolling (non-active) rows — plain Text, no animation.
    static func interludeGlyphs(durationMs: Int) -> String {
        Array(repeating: "♪", count: interludeNoteCount(durationMs: durationMs)).joined(separator: " ")
    }

    // The active card's version: each note is its own Text so it can pulse independently.
    // `isActive` gates the animation — a cue merely scrolled into view (dragging) shows the
    // notes at rest; only the cue actually driving playback animates.
    @ViewBuilder
    func interludeNotesRow(durationMs: Int, isActive: Bool, fontSize: CGFloat) -> some View {
        let count = Self.interludeNoteCount(durationMs: durationMs)
        HStack(spacing: fontSize * 0.3) {
            ForEach(0..<count, id: \.self) { i in
                Text("♪")
                    .font(.system(size: fontSize))
                    .modifier(InterludeNotePulse(isActive: isActive, delay: Double(i) * 0.15))
            }
        }
    }
}

// Staggered scale/opacity pulse, one phase-offset per note so the row reads as a left-to-right
// wave rather than every note pulsing in lockstep. Starts/stops with `isActive` rather than
// running unconditionally, so scrolling past a distant interlude in the list doesn't animate it.
private struct InterludeNotePulse: ViewModifier {
    let isActive: Bool
    let delay: Double
    @State private var isPulsed = false

    // Applies the current pulse state; the animation itself is driven by `startIfNeeded`.
    func body(content: Content) -> some View {
        content
            .scaleEffect(isActive && isPulsed ? 1.3 : 1.0)
            .opacity(isActive ? (isPulsed ? 1.0 : 0.5) : 1.0)
            .onAppear { startIfNeeded() }
            .onChange(of: isActive) { _, active in
                if active {
                    startIfNeeded()
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { isPulsed = false }
                }
            }
    }

    // Kicks off the repeating pulse animation, staggered by `delay`. No-op when not active.
    private func startIfNeeded() {
        guard isActive else { return }
        withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true).delay(delay)) {
            isPulsed = true
        }
    }
}
