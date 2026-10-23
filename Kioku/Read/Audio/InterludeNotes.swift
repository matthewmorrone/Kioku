import SwiftUI

// A musical interlude (a non-speech ♪ cue) as a row of note glyphs scaled to its duration, so a
// four-second gap and a three-minute instrumental break look different. Shown by the lyrics card
// and the full-screen word view alike, so both mark an interlude the same way. While `isActive`
// (the interlude is the one playing) the notes follow the music from the song's precomputed pulse
// map (SongPulseMap): they hit on the beats, their size tracks how loud this part is relative to
// the rest of the song, and quiet stretches pulse every other beat while loud ones pulse every
// beat. Otherwise they sit at rest. Layout: the notes in one row.
struct InterludeNotes: View {
    @ObservedObject var controller: AudioPlaybackController
    let durationMs: Int
    let isActive: Bool
    let fontSize: CGFloat

    var body: some View {
        let count = Self.noteCount(durationMs: durationMs)
        if isActive, let map = controller.pulseMap {
            // Timing reads the player's clock each frame, so pausing freezes the notes and resuming or
            // seeking lands them on the beat at the new position; each note trails the one to its left
            // so the hit ripples across the row.
            TimelineView(.animation) { _ in
                let t = controller.audibleSeconds() + Self.visualLead
                HStack(spacing: fontSize * 0.3) {
                    ForEach(0..<count, id: \.self) { i in
                        let noteTime = t - Double(i) * Self.noteLag
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

    // One note per ~4s of gap, clamped to 1-3 so a multi-minute intro/outro doesn't overrun the row.
    static func noteCount(durationMs: Int) -> Int {
        max(1, min(3, Int((Double(durationMs) / 4000.0).rounded(.up))))
    }

    // Space-separated note glyphs, for places that draw plain text (the lyrics card's scrolling rows).
    static func glyphs(durationMs: Int) -> String {
        Array(repeating: "♪", count: noteCount(durationMs: durationMs)).joined(separator: " ")
    }

    // Seconds each note trails the one to its left.
    static let noteLag = 0.05

    // Seconds the first note runs ahead of the audio: a frame reaches the screen a display refresh or
    // two after it's computed, and a kick reads as in time only if the eye gets it no later than the ear.
    static let visualLead = 0.04
}
