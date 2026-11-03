import Foundation
import LyricAlignment

// How well a whole song's alignment matches its audio (AlignmentFit), and which songs the user has
// asked not to be warned about. Each cue carries its line's fit on its checkpoints
// (CueCharTiming.confidence); the song's score is the mean over lines. A low one means lines sit
// where they don't sound like their lyrics: placed wrongly, or the lyrics differ from what is sung.
enum AlignmentConfidence {
    private static let dismissedKey = "alignmentConfidenceDismissedNotes"

    // One cue's fit: the mean of its scored checkpoints, nil when none was scored.
    private static func fit(of cue: SubtitleCue) -> Float? {
        let scores = cue.checkpoints.compactMap(\.confidence)
        guard scores.isEmpty == false else { return nil }
        return scores.reduce(0, +) / Float(scores.count)
    }

    // The mean line fit over `cues`, 0...1; nil when no cue was scored (SRT import, transcription,
    // or a note aligned before fits were kept).
    static func score(of cues: [SubtitleCue]) -> Float? {
        let fits = cues.compactMap(fit(of:))
        guard fits.isEmpty == false else { return nil }
        return fits.reduce(0, +) / Float(fits.count)
    }

    // How many scored lines don't fit their span, out of how many were scored, when the song's
    // score is low enough to warn about; else nil.
    static func warning(for cues: [SubtitleCue]) -> (weakLines: Int, scoredLines: Int)? {
        guard let score = score(of: cues), score < AlignmentFit.warningThreshold else { return nil }
        let fits = cues.compactMap(fit(of:))
        return (fits.filter { $0 < AlignmentFit.weakLineThreshold }.count, fits.count)
    }

    // Whether the user chose "Don't Show Again" for this note's song.
    static func isDismissed(noteID: UUID?, defaults: UserDefaults = .standard) -> Bool {
        guard let noteID else { return false }
        return (defaults.stringArray(forKey: dismissedKey) ?? []).contains(noteID.uuidString)
    }

    // Remembers that this note's song should no longer show the popup.
    static func dismiss(noteID: UUID?, defaults: UserDefaults = .standard) {
        guard let noteID, isDismissed(noteID: noteID, defaults: defaults) == false else { return }
        defaults.set((defaults.stringArray(forKey: dismissedKey) ?? []) + [noteID.uuidString], forKey: dismissedKey)
    }
}
