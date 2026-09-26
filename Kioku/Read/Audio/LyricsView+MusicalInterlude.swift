import SwiftUI

// Non-speech (♪) cue display: a row of note glyphs scaled to the interlude's duration — a
// four-second gap and a three-minute instrumental break both used to render as the exact same
// single "♪", giving no sense of how long the wait is. The active card additionally pulses the
// notes in sequence while that cue is the one actually playing, as a "still going" signal.
// Persisted cue text itself is untouched (still a plain "♪" — SubtitleParser.isNonSpeechCue
// keeps working on it); this is a display-time expansion in both the active card and the
// scrolling rows. The active card's notes follow the music: their size tracks its loudness and
// their pulse its busyness (InterludeRhythm), so a quiet intro gets small, gently pulsing notes
// and a loud section big, quick ones.
extension LyricsView {
    // Whether the cue at `index` is a non-speech (♪) marker rather than a sung line.
    func isNonSpeechCue(at index: Int) -> Bool {
        guard index >= 0, index < cues.count else { return false }
        return SubtitleParser.isNonSpeechCue(cues[index].text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // One note per ~4s of gap, clamped to 1-3 so a multi-minute intro/outro doesn't overrun the card.
    static func interludeNoteCount(durationMs: Int) -> Int {
        max(1, min(3, Int((Double(durationMs) / 4000.0).rounded(.up))))
    }

    // Space-separated note glyphs for the scrolling (non-active) rows — plain Text, no animation.
    static func interludeGlyphs(durationMs: Int) -> String {
        Array(repeating: "♪", count: interludeNoteCount(durationMs: durationMs)).joined(separator: " ")
    }

    // The active card's version: each note pulses independently, staggered left-to-right.
    // `isActive` gates the animation entirely — a cue merely scrolled into view (dragging)
    // shows the notes at rest, and the pulse only renders while that cue is actually playing.
    // The pulse phase and size come from the controller's rhythm tracker, which only advances
    // while audio plays: pausing freezes the notes in place and resuming continues from there.
    @ViewBuilder
    func interludeNotesRow(durationMs: Int, isActive: Bool, fontSize: CGFloat) -> some View {
        let count = Self.interludeNoteCount(durationMs: durationMs)
        if isActive {
            TimelineView(.animation) { _ in
                HStack(spacing: fontSize * 0.3) {
                    ForEach(0..<count, id: \.self) { i in
                        Text("♪")
                            .font(.system(size: fontSize))
                            .modifier(InterludeNotePulse(phase: controller.rhythmPhase, loudness: controller.rhythmLoudness, index: i))
                    }
                }
            }
        } else {
            HStack(spacing: fontSize * 0.3) {
                ForEach(0..<count, id: \.self) { i in
                    Text("♪").font(.system(size: fontSize))
                }
            }
        }
    }
}

// Scale/opacity pulse from the rhythm tracker: `phase` (in cycles) offset per note index so the row
// reads as a left-to-right wave, and `loudness` setting the notes' resting size and pulse depth.
private struct InterludeNotePulse: ViewModifier {
    let phase: Double
    let loudness: Double
    let index: Int

    // Fraction of a cycle each note trails the one before it.
    private static let stagger = 0.14

    // Applies this note's size and opacity for the current phase and loudness.
    func body(content: Content) -> some View {
        let p = phase - Double(index) * Self.stagger
        let wave = sin((p - p.rounded(.down)) * Double.pi)
        // Quiet (~-35 dB) → 0, loud (~-15 dB) → 1.
        let energy = min(1, max(0, (loudness - 0.3) / 0.4))
        content
            .scaleEffect((0.7 + energy * 0.7) * (1.0 + wave * (0.15 + energy * 0.25)))
            .opacity(0.45 + wave * 0.55)
    }
}
