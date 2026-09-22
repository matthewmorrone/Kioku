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
    // The pulse phase is derived from `controller.currentTimeMs` (the audio clock) rather than
    // a free-running UI timer, so it stays "in time" with the music: pausing freezes it exactly
    // in place, and resuming continues from the same phase instead of restarting.
    @ViewBuilder
    func interludeNotesRow(durationMs: Int, isActive: Bool, fontSize: CGFloat) -> some View {
        let count = Self.interludeNoteCount(durationMs: durationMs)
        if isActive {
            TimelineView(.animation) { _ in
                HStack(spacing: fontSize * 0.3) {
                    ForEach(0..<count, id: \.self) { i in
                        Text("♪")
                            .font(.system(size: fontSize))
                            .modifier(InterludeNotePulse(timeMs: controller.currentTimeMs, index: i))
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

// Scale/opacity pulse driven purely by the playback clock: `phase` is `timeMs` reduced modulo
// the pulse period, offset per note index so the row reads as a left-to-right wave. Being a pure
// function of `timeMs` (rather than a `repeatForever` animation kicked off in `onAppear`) means
// the wave's position always matches where the song actually is, instead of an independent timer
// that drifts relative to playback across pause/resume/seek.
private struct InterludeNotePulse: ViewModifier {
    let timeMs: Int
    let index: Int

    private static let periodMs: Double = 1100
    private static let staggerMs: Double = 150

    // Computes this note's phase from `timeMs` and applies the resulting scale/opacity.
    func body(content: Content) -> some View {
        let offset = Double(timeMs) - Double(index) * Self.staggerMs
        let rawRemainder = offset.truncatingRemainder(dividingBy: Self.periodMs)
        let phase = (rawRemainder < 0 ? rawRemainder + Self.periodMs : rawRemainder) / Self.periodMs
        let wave = sin(phase * Double.pi)
        content
            .scaleEffect(1.0 + wave * 0.3)
            .opacity(0.5 + wave * 0.5)
    }
}
