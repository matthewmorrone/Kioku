import Foundation

// Captures the editor inputs that require a full attributed-text rebuild when they change.
struct RichTextEditorStyleSignature: Equatable {
    let textSize: Double
    let lineSpacing: Double
    let kerning: Double
    let isLineWrappingEnabled: Bool
    let isEditMode: Bool
}