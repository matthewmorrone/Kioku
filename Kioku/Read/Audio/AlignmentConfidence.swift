import Foundation

// How sure the forced aligner is of a whole song's alignment, and which songs the user has asked
// not to be warned about. The score is the mean of the checkpoints' confidences
// (CueCharTiming.confidence); a low one means the lyrics probably differ from what is sung.
enum AlignmentConfidence {
    // A song scoring under this gets the "not confident" popup after aligning. A starting point to
    // tune on real songs.
    static let warningThreshold: Float = 0.5
    private static let dismissedKey = "alignmentConfidenceDismissedNotes"

    // The mean checkpoint confidence over `cues`, 0...1; nil when no checkpoint was scored (SRT
    // import, transcription, or a note aligned before confidences were kept).
    static func score(of cues: [SubtitleCue]) -> Float? {
        let scores = cues.flatMap(\.checkpoints).compactMap(\.confidence)
        guard scores.isEmpty == false else { return nil }
        return scores.reduce(0, +) / Float(scores.count)
    }

    // The score as a whole percent when it is low enough to warn about, else nil.
    static func warningPercent(for cues: [SubtitleCue]) -> Int? {
        guard let score = score(of: cues), score < warningThreshold else { return nil }
        return Int((score * 100).rounded())
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
