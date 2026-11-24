import Foundation

// What a word's speech bubble does with its meaning: say it as is, say something else, or say nothing.
enum LyricBubbleVerdict: Equatable {
    case keep
    case replace(String)
    case hide
}

// The explicit lists behind the bubbles' wording. A particle's meaning in a breakdown or the
// dictionary is often a label for its grammar role ("topic marker", "explanatory ending"), which
// tells the listener nothing about the word. Labels on the blacklist get no bubble; labels on the
// replacement list say a plain meaning instead. Both lists are hand-kept on purpose: add a line
// here when a new label shows up. Matching is on the whole words of the lowercased meaning.
enum LyricBubbleRules {
    // Whole meanings (lowercased, exactly) that say something else, checked before everything
    // else, for labels that would otherwise be hidden as emphasis ("emphatic marker" is こそ).
    static let exactReplacements: [String: String] = [
        "emphatic marker": "especially",
        "emphatic focus marker": "especially",
        // Sentence-final よ.
        "emphatic ending": "!",
        "emphatic sentence ending": "!",
        "emphatic assertion": "!",
        "urging emphasis": "!"
    ]

    // Sentence-ending labels: checked before the replacements, so a sentence-ending の is never "of".
    static let endingWords: Set<String> = ["ending", "explanatory", "emphatic", "emphasis"]

    // Phrases or words in a meaning that mean it is a replaced label, with the text said instead.
    static let replacements: [(label: String, text: String)] = [
        ("seeking agreement", "right?"),
        ("possessive", "of"),
        ("attributive", "of")
    ]

    // Words that mark a meaning as a bare grammar label.
    static let blacklistedWords: Set<String> = ["marker", "linker", "linking", "connective", "particle", "agreement", "assertion", "urging"]
    // Phrases that do the same.
    static let blacklistedPhrases: [String] = ["state of"]
    // Openers of the dictionary's role descriptions ("indicates the subject of a sentence").
    static let blacklistedOpeners: [String] = ["indicates ", "nominalizes ", "marks ", "substitutes for "]

    // The verdict for a meaning: exact replacements, then ending labels hide, then the replacement
    // list, then the blacklist.
    static func verdict(for definition: String) -> LyricBubbleVerdict {
        let lowered = definition.lowercased()
        if let text = exactReplacements[lowered.trimmingCharacters(in: .whitespacesAndNewlines)] { return .replace(text) }
        let words = Set(lowered.split(whereSeparator: { $0.isLetter == false }).map(String.init))
        if words.isDisjoint(with: endingWords) == false { return .hide }
        for (label, text) in replacements where lowered.contains(label) { return .replace(text) }
        if words.isDisjoint(with: blacklistedWords) == false
            || blacklistedPhrases.contains(where: { lowered.contains($0) })
            || blacklistedOpeners.contains(where: { lowered.hasPrefix($0) }) {
            return .hide
        }
        return .keep
    }
}
