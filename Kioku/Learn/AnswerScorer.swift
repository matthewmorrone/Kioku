import Foundation

// Grades a typed answer against the expected kanji/kana/English string for a Fill in the Blank
// question, without calling out to an LLM. A Japanese answer must be spelled exactly (katakana and
// hiragana are interchangeable, and romaji is converted to kana first): one kana is often the whole
// difference between two words (びょういん hospital, びよういん beauty salon). An English answer folds
// dictionary scaffolding and tolerates one typo on longer words. `nonisolated` (like
// `RomajiToKana`/`KanaNormalizer`, which it composes) since it's pure, stateless comparison logic.
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
        let expectsJapanese = ScriptClassifier.containsJapanese(trimmedExpected)
        var normalizedExpected = normalize(trimmedExpected)

        guard trimmedInput.isEmpty == false else {
            return Verdict(isCorrect: false, normalizedInput: "", normalizedExpected: normalizedExpected)
        }

        // Romaji input is converted to kana only when a Japanese answer is expected, so "tabemono"
        // matches たべもの while an English answer ("some", "name") is compared as typed. Against a
        // kanji-expected answer the conversion simply won't match, which is correct — a kana/romaji
        // answer shouldn't pass a kanji-production question.
        var normalizedInput: String
        if expectsJapanese,
           ScriptClassifier.containsJapanese(trimmedInput) == false,
           let romaji = RomajiToKana.convert(trimmedInput) {
            normalizedInput = normalize(romaji.kana)
            // Hepburn writes ず and づ both as "zu" (じ and ぢ as "ji"), so a romaji answer can't be
            // held to that distinction: tsuzuku is a correct romanization of つづく. Typed kana is.
            normalizedInput = KanaNormalizer.normalizeForFuriganaAlignment(normalizedInput)
            normalizedExpected = KanaNormalizer.normalizeForFuriganaAlignment(normalizedExpected)
        } else {
            normalizedInput = normalize(trimmedInput)
        }

        let isCorrect: Bool
        if normalizedInput == normalizedExpected {
            isCorrect = true
        } else if expectsJapanese {
            isCorrect = false
        } else {
            // Tolerate one small typo in English, scaled to the answer's length so short words still
            // require an exact match ("cat" for "car" is a different word, not a typo).
            let distance = editDistance(normalizedInput, normalizedExpected)
            let maxAllowed = normalizedExpected.count >= 4 ? 1 : 0
            isCorrect = distance <= maxAllowed
        }

        return Verdict(isCorrect: isCorrect, normalizedInput: normalizedInput, normalizedExpected: normalizedExpected)
    }

    // Folds katakana to hiragana and lowercases (for any incidental latin characters). Kana spelling
    // is otherwise kept as typed: づ/ず and small/large kana are different spellings. Text with no
    // Japanese in it is additionally folded as English prose — see `normalizeEnglish`.
    private static func normalize(_ text: String) -> String {
        let normalized = KanaNormalizer.katakanaToHiragana(text).lowercased()
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
