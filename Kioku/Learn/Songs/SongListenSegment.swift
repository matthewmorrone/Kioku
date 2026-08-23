import Foundation

// One utterance's worth of text plus which voice should read it — the atomic unit
// SongListenScript.build produces and SongListenAudioService synthesizes in order. Kept as
// plain data (no logic) so it can sit alongside its two companion enums in one file per the
// "pure data types may be grouped" rule.
struct SongListenSegment: Equatable, Sendable {
    let lineIndex: Int
    let kind: SongListenSegmentKind
    let text: String
    let language: SongListenLanguage
}

// What role a segment plays within its line — drives the silence gap inserted after it
// (SongListenAudioService.silenceBuffer) and lets the script builder self-document why the
// segment exists.
enum SongListenSegmentKind: Equatable, Sendable {
    case sentence
    case translation
    case wordSurface
    case wordDefinition
}

// Which voice reads a segment. Kept as its own type (rather than reusing some existing
// language enum) since the only thing that matters here is "Japanese voice or English voice."
enum SongListenLanguage: Equatable, Sendable {
    case japanese
    case english
}
