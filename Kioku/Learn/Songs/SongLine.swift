import Foundation

// One parsed line in the breakdown. Lines are 1-indexed to match the prompt's "Line N" labels.
// For repeated chorus lines, `reference` is non-nil and `words`/`gist`/`grammarNote` may be empty —
// the consumer follows the reference to fetch the referenced line's content on demand.
//
// The reveal-stage cap is a property of the line itself, not the view that renders it: a line
// with no romaji has one fewer reveal stage than a line that does. Centralizing on the model
// keeps the stepper and the card from drifting if the reveal pipeline ever gains a new layer.
// `nonisolated`: pure data consumed off the main actor by the streaming parse path
// (StreamedTextAccumulator compares parses; SongListenScript reads lines) — under the
// module's default MainActor isolation the synthesized Equatable would otherwise be
// main-actor-only.
nonisolated struct SongLine: Codable, Equatable, Identifiable, Sendable {
    let index: Int
    let original: String
    let romaji: String?
    let words: [SongWord]
    let gist: String?
    let grammarNote: String?
    let reference: LineReference?

    var id: Int { index }

    // Maximum reveal stage this line can advance to, counting only populated optional layers.
    // Stage 0 always shows the Japanese original; each populated layer adds one stage on top.
    // SongStepperView caps the per-line counter against this; SongLineCard gates the
    // "Tap to reveal …" affordance and the layer-visibility checks against it.
    var revealStageCap: Int {
        var cap = 0
        if romaji != nil { cap += 1 }
        if words.isEmpty == false { cap += 1 }
        if gist != nil || grammarNote != nil { cap += 1 }
        return cap
    }
}

// Lookup key for a word-list headword's per-kanji-run furigana (SongStepperView's
// wordFuriganaByKey / SongLineCard's wordFurigana). Keying by surface alone would collide
// when the same word appears on more than one line with a different resolved reading — e.g.
// a Read-tab correction pinned on one occurrence but not another — so line identity is part
// of the key, not just the surface text.
nonisolated struct WordFuriganaKey: Hashable {
    let lineIndex: Int
    let surface: String
}

// Where a line card's content stands (see SongBreakdownProgressComposer):
//   .noteText  — just the note's own line; the model hasn't produced anything for it (yet)
//   .streaming — the model is currently writing this line's section; highlighted
//   .ready     — the line's breakdown is complete (or came from a cached breakdown)
// Cards look the same in .noteText and .ready — the phase only drives the streaming
// highlight and gates the "recovered from older data" notice to real breakdown lines.
nonisolated enum SongLineCardPhase: Equatable {
    case noteText
    case streaming
    case ready
}

// One row of the breakdown scroll: the line to render plus its phase. `id` is assigned by
// the composer and is unique per row even when the model repeats a line number, so
// SwiftUI's ForEach / scrollTo never see duplicate identities.
nonisolated struct SongLineDisplayItem: Identifiable, Equatable {
    let id: String
    let line: SongLine
    let phase: SongLineCardPhase
}
