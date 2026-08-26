import Foundation

// One utterance's worth of text plus which voice should read it — the atomic unit
// SongListenScript.build produces and SongListenAudioService synthesizes in order. Kept as
// plain data (no logic) so it can sit alongside its two companion enums in one file per the
// "pure data types may be grouped" rule.
//
// All three types here are `nonisolated`: they're built and consumed entirely inside
// SongListenAudioService, which is itself `nonisolated` (see that file's header comment) —
// without this, the module's default MainActor isolation would make even their synthesized
// `Equatable` conformances MainActor-isolated, unusable from that nonisolated context.
nonisolated struct SongListenSegment: Equatable, Sendable {
    let lineIndex: Int
    let kind: SongListenSegmentKind
    let text: String
    let language: SongListenLanguage
}

// What role a segment plays within its line — drives the silence gap inserted after it
// (SongListenAudioSink.writeSilence) and lets the script builder self-document why the
// segment exists.
nonisolated enum SongListenSegmentKind: Equatable, Sendable {
    case sentence
    case translation
    case wordSurface
    case wordDefinition
}

// Which voice reads a segment. Kept as its own type (rather than reusing some existing
// language enum) since the only thing that matters here is "Japanese voice or English voice."
nonisolated enum SongListenLanguage: Equatable, Sendable {
    case japanese
    case english
}

// One step in the render pipeline: either a spoken segment, or a slice of the song's own
// source audio (the sung line itself) copied in verbatim. Kept distinct from
// SongListenSegment rather than adding a `.clip` case there — a clip has no `text` or TTS
// `language`, just a time range into a different file.
nonisolated enum SongListenStep: Equatable, Sendable {
    case speech(SongListenSegment)
    case clip(lineIndex: Int, startMs: Int, endMs: Int)
}
