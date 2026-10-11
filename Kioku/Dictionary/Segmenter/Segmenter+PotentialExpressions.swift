import Foundation

// Whether a deinflection path may carry a surface to an expression entry. Split out of
// Segmenter+LemmaResolution.swift, whose resolvedTrieLemmasBySource is the only caller.
extension Segmenter {
    // Chain label of the deinflection rules' "potentialForms" group (開けて → 開く), as the deinflector
    // normalizes it.
    static let potentialLabel = Deinflector.normalizedRuleLabel("potentialForms")

    // Whether `path` reaches an expression (口を開く) through a potential step whose potential form
    // ends in a dictionary verb of its own: 口を開ける ends in 開ける, a verb in JMdict, so 口を開けて is
    // 口|を|開けて and not "can open one's mouth" as one phrase. A potential JMdict doesn't list
    // (戻せる) is no other word, so 元に戻せなかった still reaches 元に戻す.
    func reachesExpressionThroughVerbHomograph(
        from surface: String,
        path: [(label: String, kanaIn: String, kanaOut: String)]
    ) -> Bool {
        var current = surface
        for transition in path {
            let next = String(current.dropLast(transition.kanaIn.count)) + transition.kanaOut
            if transition.label == Self.potentialLabel,
               potentialEndsInDictionaryVerb(potential: current, plain: next, ending: transition.kanaIn) {
                return true
            }
            current = next
        }
        return false
    }

    // Whether the expression's own final verb (開く of 口を開く: the longest dictionary verb ending
    // `plain`) has a potential (開ける of 口を開ける) that is a dictionary verb too. Only that verb is
    // compared: a shorter stretch can spell an unrelated pair by chance (かれる/かる inside
    // お目にかかれる/お目にかかる). Stretches no longer than the conjugated ending (ける) are not words.
    private func potentialEndsInDictionaryVerb(potential: String, plain: String, ending: String) -> Bool {
        let potentialCharacters = Array(potential)
        let plainCharacters = Array(plain)
        let stemLength = potentialCharacters.count - ending.count
        guard stemLength > 0, plainCharacters.count >= stemLength else { return false }
        for start in 1..<stemLength {
            let plainTail = String(plainCharacters[start...])
            guard trie.contains(plainTail), PartOfSpeech.isVerb(trie.partOfSpeech(for: plainTail)) else { continue }
            let potentialTail = String(potentialCharacters[start...])
            return trie.contains(potentialTail) && PartOfSpeech.isVerb(trie.partOfSpeech(for: potentialTail))
        }
        return false
    }
}
