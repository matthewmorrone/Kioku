import Foundation

// Represents one morphological token produced by MeCab's analysis of input text.
nonisolated struct MeCabNode {
    // The surface form (text as it appears in the input).
    let surface: String

    // The full CSV feature string from MeCab (POS, conjugation, base form, reading, etc.).
    let feature: String

    // The byte length of the surface in the original UTF-8 input.
    let byteLength: Int

    // The byte offset of the surface from the start of the original UTF-8 input.
    let byteOffset: Int

    // Splits the feature CSV and returns the field at the given index, or nil if out of bounds.
    func featureField(at index: Int) -> String? {
        let fields = feature.split(separator: ",", omittingEmptySubsequences: false)
        guard index < fields.count else { return nil }
        let value = String(fields[index])
        return value == "*" ? nil : value
    }
}
