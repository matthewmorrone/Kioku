import Foundation

// The unified parsed model for every timed-text source the app reads. An SRT subtitle track and a
// Praat TextGrid forced-alignment grid both decode into this single shape, replacing the former
// SubtitleCue-vs-TextGridFile split at the parse boundary. Downstream the document is still lowered
// into the runtime pair the renderer consumes ([SubtitleCue] + CueCharTimings); this type unifies
// the *input* side so adding a new format (VTT, ASS karaoke) means producing a TimedTextDocument and
// nothing else.

// One stretch of text with a start/end time in integer milliseconds. The atom shared by every
// timed-text format: a TextGrid interval, an SRT cue body, a word/mora within a karaoke line.
nonisolated struct TimedSpan: Equatable {
    var startMs: Int
    var endMs: Int
    var text: String
}

// One named track of timed spans. A TextGrid carries several (e.g. "segments", "words", "phones");
// an SRT carries exactly one (the line tier). The name drives finest-tier preference during binding.
nonisolated struct TimedTier: Equatable {
    var name: String
    var spans: [TimedSpan]
}

// A parsed timed-text document: the total media duration (when the format records it — TextGrid xmax;
// nil for SRT) plus its ordered tiers.
nonisolated struct TimedTextDocument: Equatable {
    var durationMs: Int?
    var tiers: [TimedTier]

    // Expresses a list of parsed SRT cues as a single-tier document so SRT and TextGrid feed the same
    // model. The cue index is intentionally not preserved here — only timing and text are part of the
    // unified shape; line identity is re-derived (1-based) by lineCues() when lowering back.
    init(subtitleCues cues: [SubtitleCue]) {
        durationMs = cues.map(\.endMs).max()
        tiers = [TimedTier(
            name: "subtitles",
            spans: cues.map { TimedSpan(startMs: $0.startMs, endMs: $0.endMs, text: $0.text) }
        )]
    }

    // Direct initializer used by parsers that build tiers themselves (TextGridParser).
    init(durationMs: Int?, tiers: [TimedTier]) {
        self.durationMs = durationMs
        self.tiers = tiers
    }

    // Collapses the document to line-level subtitle cues by selecting the coarsest non-empty tier
    // (fewest spans = the line/phrase tier; finer tiers carry word/phone timing) and emitting its
    // non-empty spans as 1-based cues. This is the single source of truth for "TextGrid stands in for
    // an SRT" — both the interactive picker and the bulk importer lower through here so they can't drift.
    func lineCues() -> [SubtitleCue] {
        let candidates = tiers.filter { tier in
            tier.spans.contains { $0.text.isEmpty == false }
        }
        guard let lineTier = candidates.min(by: { $0.spans.count < $1.spans.count }) else {
            return []
        }
        var cues: [SubtitleCue] = []
        var index = 1
        for span in lineTier.spans where span.text.isEmpty == false {
            cues.append(SubtitleCue(
                index: index,
                startMs: span.startMs,
                endMs: span.endMs,
                text: span.text
            ))
            index += 1
        }
        return cues
    }
}
