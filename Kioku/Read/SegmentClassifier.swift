import Foundation

// Shared classifier for segmentation output: tells callers which segments are pure
// punctuation / whitespace / symbols and therefore shouldn't pick up segment styling
// (color alternation, ruby, unknown-segment highlights). Used by both the TextKit 2
// renderer (ReadTextStyleResolver) and the CoreText renderer
// (KiokuCoreTextAttributedStringBuilder) so the two paths classify identically.
enum SegmentClassifier {

    // True when the segment contains only non-lexical characters and should therefore
    // skip styling. Empty strings are treated as non-lexical.
    static func isNonLexical(_ segmentText: String) -> Bool {
        guard segmentText.isEmpty == false else { return true }
        return segmentText.unicodeScalars.allSatisfy { nonLexicalScalars.contains($0) }
    }

    // Character set covering whitespace, punctuation, symbols, and common CJK
    // brackets/delimiters that Foundation's punctuationCharacters may not classify
    // correctly on its own.
    static let nonLexicalScalars: CharacterSet = {
        var cs = CharacterSet.whitespacesAndNewlines
        cs.formUnion(.punctuationCharacters)
        cs.formUnion(.symbols)
        for scalar in "「」『』【】〔〕〈〉《》（）、。・〜…―～".unicodeScalars {
            cs.insert(scalar)
        }
        return cs
    }()
}
