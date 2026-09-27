import SwiftUI

// Non-speech (♪) cue display: a row of note glyphs scaled to the interlude's duration, so a
// four-second gap and a three-minute instrumental break look different. The active card
// additionally pulses the notes in sequence while that cue is the one actually playing, as a "still
// going" signal. Persisted cue text itself is untouched (still a plain "♪" —
// SubtitleParser.isNonSpeechCue keeps working on it); this is a display-time expansion in both the
// active card and the scrolling rows. The active card's notes follow the music from the song's
// precomputed pulse map (SongPulseMap): they hit on the beats, their size tracks how loud this
// part is relative to the rest of the song, and quiet stretches pulse every other beat while loud
// ones pulse every beat — so a soft intro gets small, slow notes and the full band big, quick ones.
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

    // The active card's version: every note hits on the song's beats, trailing slightly
    // left-to-right so the hit ripples across the row. `isActive` gates the animation entirely — a
    // cue merely scrolled into view (dragging) shows the notes at rest, and the pulse only renders
    // while that cue is actually playing. Timing reads the player's clock each frame, so pausing
    // freezes the notes and resuming or seeking lands them on the beat at the new position.
    @ViewBuilder
    func interludeNotesRow(durationMs: Int, isActive: Bool, fontSize: CGFloat) -> some View {
        let count = Self.interludeNoteCount(durationMs: durationMs)
        if isActive, let map = controller.pulseMap {
            TimelineView(.animation) { _ in
                let t = controller.audibleSeconds() + Self.interludeVisualLead
                HStack(spacing: fontSize * 0.3) {
                    ForEach(0..<count, id: \.self) { i in
                        let noteTime = t - Double(i) * Self.interludeNoteLag
                        Text("♪")
                            .font(.system(size: fontSize))
                            .modifier(InterludeNotePulse(
                                pulse: map.pulse(at: noteTime),
                                loudness: map.loudness(at: noteTime),
                                fontSize: fontSize
                            ))
                    }
                }
            }
        } else {
            HStack(spacing: fontSize * 0.3) {
                ForEach(0..<count, id: \.self) { _ in
                    Text("♪").font(.system(size: fontSize))
                }
            }
        }
    }

    // Seconds each note trails the one to its left.
    static let interludeNoteLag = 0.05

    // Seconds the first note runs ahead of the audio: a frame reaches the screen a display refresh or
    // two after it's computed, and a kick reads as in time only if the eye gets it no later than the ear.
    static let interludeVisualLead = 0.04
}

// Scale/opacity/hop for one note: `loudness` (0…1, relative to the song) sets its resting size and
// how hard it kicks, `pulse` (1 on a beat, decaying) the kick itself. The kick and hop grow with
// loudness squared, so quiet passages stay small and calm and only the loudest parts go big.
private struct InterludeNotePulse: ViewModifier {
    let pulse: Double
    let loudness: Double
    let fontSize: CGFloat

    // Applies this note's size, opacity and hop for the current beat pulse and loudness.
    func body(content: Content) -> some View {
        let drama: Double = loudness * loudness
        let restingScale: Double = 0.5 + loudness * 1.1
        let kick: Double = 0.08 + drama * 1.1
        let scale: Double = restingScale * (1.0 + pulse * kick)
        let opacity: Double = 0.5 + pulse * 0.5
        let hop: Double = -pulse * drama * Double(fontSize) * 0.7
        content
            .scaleEffect(scale)
            .offset(y: hop)
            .opacity(opacity)
    }
}
