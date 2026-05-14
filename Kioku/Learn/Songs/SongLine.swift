import Foundation

// One parsed line in the breakdown. Lines are 1-indexed to match the prompt's "Line N" labels.
// For repeated chorus lines, `reference` is non-nil and `words`/`gist`/`grammarNote` may be empty —
// the consumer follows the reference to fetch the referenced line's content on demand.
//
// The reveal-stage cap is a property of the line itself, not the view that renders it: a line
// with no romaji has one fewer reveal stage than a line that does. Centralizing on the model
// keeps the stepper and the card from drifting if the reveal pipeline ever gains a new layer.
struct SongLine: Codable, Equatable, Identifiable, Sendable {
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
