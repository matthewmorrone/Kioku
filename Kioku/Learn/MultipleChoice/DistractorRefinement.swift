import Foundation

// What the on-device model is asked about one multiple-choice question, and what comes back.
// Separated from the Foundation Models client so the parts worth being sure about — which model
// suggestions are safe to put in front of the user — are plain values that test without a device.

// The question a refinement request is about, in the terms the model needs.
nonisolated struct DistractorRequest: Equatable, Sendable {
    let prompt: String
    let correct: String
    // Every accepted answer for this item, not just the one shown: an invented option that happens
    // to be another gloss of the same word is a second correct answer, not a distractor.
    let acceptedAnswers: [String]
    // The pool's own candidates, already narrowed by the heuristic selector.
    let candidates: [String]
    // Which side of the word the options are written on — decides whether an invented option has
    // to be a real dictionary word (Japanese) and what script it must be in.
    let answerField: StudyField
}

// The model's verdict: which pool candidates it would use, whether the pool was deep enough to
// make a fair question at all, and what it would add if it wasn't.
nonisolated struct DistractorRefinement: Equatable, Sendable {
    // Pool candidates, best first. Anything the model returns that wasn't offered is discarded.
    let chosen: [String]
    // The model's own read on whether the pool could supply convincing wrong answers — the
    // judgement a count can't make, since three same-class options can still be three words no one
    // would ever confuse with the answer.
    let poolIsTooShallow: Bool
    // Words the model proposes adding. Japanese ones are worthless unless they're real, so the
    // caller verifies each against JMdict before any of them reaches a question.
    let invented: [String]
}

// The rules that decide what of a model's answer is usable. Every one of them exists because the
// on-device model is small and will, given the chance, return the correct answer as a distractor,
// repeat itself, echo a candidate it was never given, or offer a synonym of the very word being
// asked about.
nonisolated enum DistractorRefinementPolicy {
    // Filters the model's pool picks down to candidates it was actually offered, in the order it
    // ranked them, without duplicates. Anything else is a hallucinated option.
    static func acceptedPicks(_ refinement: DistractorRefinement, request: DistractorRequest) -> [String] {
        let offered = Set(request.candidates)
        var seen: Set<String> = []
        return refinement.chosen.filter { pick in
            guard offered.contains(pick) else { return false }
            return seen.insert(pick).inserted
        }
    }

    // Filters proposed new options down to the ones safe to show. `isRealWord` is asked only about
    // Japanese answers — an English gloss has no dictionary form to check, and a wrong meaning
    // doesn't need to be a word at all to be a fair distractor.
    static func acceptedInventions(
        _ refinement: DistractorRefinement,
        request: DistractorRequest,
        alreadyChosen: [String],
        isRealWord: (String) -> Bool
    ) -> [String] {
        var seen = Set(alreadyChosen).union(request.candidates).union(request.acceptedAnswers)
        seen.insert(request.correct)
        var result: [String] = []
        for candidate in refinement.invented {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            // A rephrasing of an accepted answer is a second right answer. Compared loosely because
            // the model returns "to eat" for a gloss stored as "eat".
            guard seen.contains(where: { matchesLoosely($0, trimmed) }) == false else { continue }
            guard scriptFits(trimmed, field: request.answerField) else { continue }
            if request.answerField != .meaning, isRealWord(trimmed) == false { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    // Whether a proposed option is written the way this side of the question is written: a kana
    // answer can't be offered a kanji option, and neither can be offered an English one.
    static func scriptFits(_ text: String, field: StudyField) -> Bool {
        switch field {
        case .kana:
            return ScriptClassifier.isPureKana(text)
        case .kanji:
            return ScriptClassifier.containsKanji(text)
        case .meaning:
            return ScriptClassifier.containsJapanese(text) == false
        }
    }

    // Case- and article-insensitive comparison, so "to eat" / "Eat" / "eat" all count as the same
    // answer. Deliberately crude: it only has to catch a model restating the answer it was given.
    static func matchesLoosely(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    // Lowercases and drops a leading article or infinitive marker, so the two spellings of one
    // answer collapse to the same string.
    private static func normalized(_ text: String) -> String {
        var value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["to ", "a ", "an ", "the "] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
