import Foundation

// Finds the characters whose width is an input-method accident rather than a choice, and proposes
// the standard form: half-width katakana and half-width Japanese punctuation become full-width
// (ｶﾞﾝﾊﾞﾚ → ガンバレ, ｢｣ → 「」), full-width letters and digits become ASCII (ｈｅａｒｔ → heart,
// １２３ → 123), and a run of dots written as periods becomes an ellipsis (．．． or ... → …).
// Other punctuation keeps its width; the renderer squeezes it instead.
nonisolated enum WidthNormalizer {
    // A run of half-width katakana / Japanese punctuation (U+FF61–FF9F), of full-width letters and
    // digits (joined by full-width spaces, so Ｓｈｉｎｅ　ｙｏｕｒ is one run), or of three or more
    // periods, full- or half-width.
    private static let runPattern = try! NSRegularExpression(
        pattern: "[\\x{FF61}-\\x{FF9F}]+|[０-９Ａ-Ｚａ-ｚ]+(?:　[０-９Ａ-Ｚａ-ｚ]+)*|[.．]{3,}"
    )

    // Proposals for every such run in `text`, in text order.
    static func proposals(in text: String) -> [TextConversion] {
        let ns = text as NSString
        return runPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let original = ns.substring(with: match.range)
            if original.allSatisfy({ $0 == "." || $0 == "．" }) {
                // One … per three dots (．．．．．． → ……).
                let ellipsis = String(repeating: "…", count: max(1, (original.count + 1) / 3))
                return TextConversion(range: match.range, original: original, replacement: ellipsis, source: .width)
            }
            // NFKC folds both directions at once and joins ﾞ/ﾟ onto the kana before them (ｶﾞ → ガ).
            let normalized = original.precomposedStringWithCompatibilityMapping
            guard normalized != original else { return nil }
            return TextConversion(range: match.range, original: original, replacement: normalized, source: .width)
        }
    }
}
