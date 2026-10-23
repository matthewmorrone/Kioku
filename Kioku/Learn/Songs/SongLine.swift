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
    // True when the model marked the whole line as a vocalization (a gist starting with
    // `[vocalization]`, see SongBreakdownParser) — "la la la", "ah", humming. Optional so
    // breakdowns cached before the marker existed decode as unmarked.
    var isVocalization: Bool? = nil
    // The model's note on where it would split or join this line's words differently from the
    // app's segmentation, or which reading it thinks is wrong (SongBreakdownPrompt rule 12's
    // **Segmentation:** line). Nil when it agreed, or for breakdowns generated without one.
    var segmentationNote: String? = nil
    // Corrections the model suggests for this line (SongBreakdownPrompt rules 12 and 13's **Fix:**
    // lines), still waiting in the Breakdown's fix list; one leaves when it's fixed or ignored. Nil
    // when there are none, or for breakdowns generated without them.
    var fixes: [SongLineFix]? = nil

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

// What a line card is doing right now (see SongBreakdownProgressComposer):
//   .streaming — the model is currently writing this line's section; ringed, with a spinner
//   .playing   — listen-along is currently speaking this line; ringed
//   .ready     — nothing in progress
nonisolated enum SongLineCardPhase: Equatable {
    case streaming
    case playing
    case ready
}

// What a line card's audio button shows: play (tap to hear this line's clip + narration) or
// pause while this line is the one being spoken. Nil at the call site hides the button (no
// breakdown yet) — see SongLiveListenController, which plays live rather than pre-rendering,
// so there's no separate "generate" step to show a down-arrow/spinner for.
nonisolated enum SongLineCardPlayState: Equatable {
    case idle
    case playing
}

// One row of the breakdown scroll: the line to render plus its phase. `id` is assigned by
// the composer and is unique per row even when the model repeats a line number, so
// SwiftUI's ForEach / scrollTo never see duplicate identities.
nonisolated struct SongLineDisplayItem: Identifiable, Equatable {
    let id: String
    let line: SongLine
    let phase: SongLineCardPhase
}
