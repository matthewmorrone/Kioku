import Foundation

// Grades a typed Japanese answer against the expected kanji/kana string for a production-direction
// quiz question (meaning→kanji, meaning→kana). Not exact-match: tolerates romaji input (converted to
// kana before comparing), kana spelling variants, and a single small typo on longer answers — without
// calling out to an LLM. `nonisolated` (like `RomajiToKana`/`KanaNormalizer`, which it composes) since
// it's pure, stateless comparison logic with no MainActor state.
nonisolated enum AnswerScorer {
    // The outcome of grading one typed answer, plus the normalized forms actually compared — useful
    // for "you typed X, expected Y" feedback UI without the caller re-deriving normalization itself.
    struct Verdict: Equatable {
        let isCorrect: Bool
        let normalizedInput: String
        let normalizedExpected: String
    }

    // Grades `input` against `expected` (the dictionary kanji headword or kana reading). An empty
    // (post-trim) input is always wrong — there's nothing to compare, and it would otherwise report
    // a misleadingly small edit distance against a short expected answer.
    static func grade(input: String, expected: String) -> Verdict {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExpected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExpected = normalize(trimmedExpected)

        guard trimmedInput.isEmpty == false else {
            return Verdict(isCorrect: false, normalizedInput: "", normalizedExpected: normalizedExpected)
        }

        // Romaji input (no kana/kanji scalars at all) is converted to kana before comparison, so
        // typing "tabemono" matches たべもの. Against a kanji-expected answer this conversion simply
        // won't match, which is correct — a kana/romaji answer shouldn't pass a kanji-production
        // question, or it wouldn't be testing kanji recall at all.
        let candidate: String
        if ScriptClassifier.containsJapanese(trimmedInput) == false,
           let romaji = RomajiToKana.convert(trimmedInput) {
            candidate = romaji.kana
        } else {
            candidate = trimmedInput
        }

        let normalizedInput = normalize(candidate)

        let isCorrect: Bool
        if normalizedInput == normalizedExpected {
            isCorrect = true
        } else {
            // Tolerate one small typo, scaled to the answer's length so short words still require an
            // exact match — a 1-edit tolerance on a 2-character word (e.g. 木 vs 本) would accept a
            // different, unrelated word rather than a typo of the right one.
            let distance = editDistance(normalizedInput, normalizedExpected)
            let maxAllowed = normalizedExpected.count >= 4 ? 1 : 0
            isCorrect = distance <= maxAllowed
        }

        return Verdict(isCorrect: isCorrect, normalizedInput: normalizedInput, normalizedExpected: normalizedExpected)
    }

    // Folds script variants (katakana→hiragana, kana spelling variants like づ/ず) and lowercases
    // (for any incidental latin characters), so equivalent spellings compare equal.
    private static func normalize(_ text: String) -> String {
        let folded = KanaNormalizer.katakanaToHiragana(text)
        return KanaNormalizer.normalizeForFuriganaAlignment(folded).lowercased()
    }

    // Standard Levenshtein edit distance, operating on Characters (extended grapheme clusters) rather
    // than UnicodeScalars, so a multi-scalar kana grapheme counts as one edit unit rather than several.
    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previousRow = Array(0...b.count)
        var currentRow = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            currentRow[0] = i
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    currentRow[j] = previousRow[j - 1]
                } else {
                    currentRow[j] = 1 + min(previousRow[j - 1], previousRow[j], currentRow[j - 1])
                }
            }
            swap(&previousRow, &currentRow)
        }
        return previousRow[b.count]
    }
}
