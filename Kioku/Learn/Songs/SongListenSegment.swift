import Foundation

// One utterance's worth of text plus which voice should read it — the atomic unit
// SongListenScript.build produces and SongLiveListenController plays in order. Kept as
// plain data (no logic) so it can sit alongside its two companion enums in one file per the
// "pure data types may be grouped" rule.
//
// All three types here are `nonisolated`: they're built by the `nonisolated` SongListenScript
// — without this, the module's default MainActor isolation would make even their synthesized
// `Equatable` conformances MainActor-isolated, unusable from that nonisolated context.
nonisolated struct SongListenSegment: Equatable, Sendable {
    let lineIndex: Int
    let kind: SongListenSegmentKind
    let text: String
    let language: SongListenLanguage
    // When non-nil, this is what actually gets synthesized instead of `text` — `text` stays
    // the display/cue form (SongLineCard's highlight-matching compares against it, e.g.
    // `word.surface`), while `spokenText` carries a pronunciation-correct substitute (kana
    // converted from the LLM's own resolved romaji) for a Japanese kanji surface whose reading
    // AVSpeechSynthesizer would otherwise have to guess. See
    // SongListenScript.spokenReading(original:romaji:).
    var spokenText: String? = nil
}

// What role a segment plays within its line — drives the gap SongLiveListenController waits
// before the next step (see its `gapSeconds(after:)`) and lets the script builder
// self-document why the segment exists.
nonisolated enum SongListenSegmentKind: Equatable, Sendable {
    case sentence
    case translation
    case wordSurface
    case wordDefinition
    case patternNote
}

// Which voice reads a segment. Kept as its own type (rather than reusing some existing
// language enum) since the only thing that matters here is "Japanese voice or English voice."
nonisolated enum SongListenLanguage: Equatable, Sendable {
    case japanese
    case english
}

// One step in the listen-along script: a spoken segment, a slice of the song's own source
// audio for a whole sung line, or a slice for one sung word. Kept distinct from
// SongListenSegment rather than adding clip cases there — a clip has no TTS `language`, just a
// time range into a different file. A word clip carries its surface so the word's row
// highlights while it plays, exactly as a synthesized `.wordSurface` segment would.
nonisolated enum SongListenStep: Equatable, Sendable {
    case speech(SongListenSegment)
    case clip(lineIndex: Int, startMs: Int, endMs: Int)
    case wordClip(lineIndex: Int, surface: String, startMs: Int, endMs: Int)
}

// One same-language stretch of a segment's text, produced by SongListenLanguageRuns. A gist
// like "contracted 愛している" becomes an English run and a Japanese run so each is read by
// the voice built for it, instead of the English voice skipping the kanji.
nonisolated struct SongListenSegmentRun: Equatable, Sendable {
    let text: String
    let language: SongListenLanguage
}
