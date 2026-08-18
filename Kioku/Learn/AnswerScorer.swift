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

    // Grades `input` against a set of accepted answers, passing if any one of them does. This is
    // how an English answer is graded: the meaning side has an open set of valid phrasings, so
    // there is no single expected string to fuzzy-match — but the word's own glosses are a bounded
    // set, and typing any of them is right. The reported verdict is the best match, so feedback
    // shows the gloss the user came closest to rather than an arbitrary one.
    static func grade(input: String, anyOf accepted: [String]) -> Verdict {
        guard let first = accepted.first else {
            return grade(input: input, expected: "")
        }
        var best = grade(input: input, expected: first)
        for candidate in accepted.dropFirst() {
            if best.isCorrect { return best }
            let verdict = grade(input: input, expected: candidate)
            // Prefer a passing verdict; failing that, keep the one whose expected form the input
            // came closest to, so the feedback line names a plausible target.
            if verdict.isCorrect
                || editDistance(verdict.normalizedInput, verdict.normalizedExpected)
                    < editDistance(best.normalizedInput, best.normalizedExpected) {
                best = verdict
            }
        }
        return best
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
    // (for any incidental latin characters), so equivalent spellings compare equal. Text with no
    // Japanese in it is additionally folded as English prose — see `normalizeEnglish`.
    private static func normalize(_ text: String) -> String {
        let folded = KanaNormalizer.katakanaToHiragana(text)
        let normalized = KanaNormalizer.normalizeForFuriganaAlignment(folded).lowercased()
        return ScriptClassifier.containsJapanese(normalized) ? normalized : normalizeEnglish(normalized)
    }

    // Folds the incidental differences between phrasings of the same English gloss, so answering
    // "eat" against a stored "to eat" — or "the bank" against "bank" — is a match rather than a
    // 3-edit miss. Deliberately conservative: it drops dictionary scaffolding (the infinitive "to",
    // articles, parenthetical qualifiers, punctuation) but never touches the content words, so two
    // genuinely different meanings can still not collide.
    private static func normalizeEnglish(_ text: String) -> String {
        var result = text
        // Parenthesised qualifiers ("(of a person)") are notes about the gloss, not part of it.
        while let open = result.firstIndex(of: "("), let close = result[open...].firstIndex(of: ")") {
            result.removeSubrange(open...close)
        }
        result = String(result.unicodeScalars.filter { scalar in
            CharacterSet.punctuationCharacters.contains(scalar) == false
        })
        var words = result.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.first == "to" { words.removeFirst() }
        if let first = words.first, ["a", "an", "the"].contains(first) { words.removeFirst() }
        return words.joined(separator: " ")
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
