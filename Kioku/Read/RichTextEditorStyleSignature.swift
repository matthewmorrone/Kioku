import Foundation

// Captures the editor inputs that require a full attributed-text rebuild when they change.
// Only typography-affecting inputs belong here: a field the attributed string doesn't depend
// on turns every flip of that field into a full TextKit re-layout of the whole note.
struct RichTextEditorStyleSignature: Equatable {
    let textSize: Double
    let lineSpacing: Double
    let kerning: Double
    let isLineWrappingEnabled: Bool
    // isEditMode deliberately excluded: applyTypography's output is identical in both modes,
    // and including it made every edit↔view toggle reset attributedText (full TK2 re-typeset
    // of the entire note) — the toggle-lag bug.
    // let isEditMode: Bool
}