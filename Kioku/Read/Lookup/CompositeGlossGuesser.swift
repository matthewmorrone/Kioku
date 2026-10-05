import Foundation

// Asks the on-device model what a whole inflected or helper-word form means, so the lookup sheet and
// the word detail screen can say "seems likely to happen" for 起こりそう and "to not want to say" for
// 言いたくない instead of leaving the reader to assemble 起こる + そう or 言う + desiderative + negative
// from the lemma's senses. The dictionary senses stay underneath: this is a labelled guess on top.
// Answers are kept in GuessedGlossStore.composite, so each form is asked about once. Every failure
// (no Apple Intelligence on the device, a refusal, an unusable reply) returns nil and nothing shows.
enum CompositeGlossGuesser {
    // The stored or freshly guessed meaning of `surface` as a whole. `lemmaLine` is what the header
    // shows under the headword (言う, 起こる + そう), `formDescription` the named inflection
    // ("desiderative · negative"), `baseGloss` the lemma's primary sense.
    @MainActor
    static func guess(
        surface: String,
        lemmaLine: String,
        formDescription: String?,
        baseGloss: String?,
        store: GuessedGlossStore = .composite
    ) async -> String? {
        if let stored = store.gloss(for: surface, in: lemmaLine) { return stored }
        let request = prompt(surface: surface, lemmaLine: lemmaLine, formDescription: formDescription, baseGloss: baseGloss)
        guard let reply = await GlossGuesser.askOnDeviceModel(prompt: request),
              let gloss = GlossGuesser.cleaned(reply) else { return nil }
        store.setGloss(gloss, for: surface, in: lemmaLine)
        return gloss
    }

    // The request: the form's parts as the app already knows them, and one short English gloss back,
    // conjugated to match the whole form rather than the lemma. A line with helper words names them
    // instead of the inflection, whose chain then only says "auxiliary".
    static func prompt(surface: String, lemmaLine: String, formDescription: String?, baseGloss: String?) -> String {
        let parts = lemmaLine.components(separatedBy: " + ")
        let lemma = parts.first ?? lemmaLine
        var facts: String
        if parts.count > 1 {
            facts = "「\(surface)」 is \(parts.map { "「\($0)」" }.joined(separator: " + "))."
        } else if let formDescription, formDescription.isEmpty == false {
            facts = "「\(surface)」 is the \(formDescription) form of 「\(lemma)」."
        } else {
            facts = "「\(surface)」 is a form of 「\(lemma)」."
        }
        if let baseGloss { facts += " 「\(lemma)」 means: \(baseGloss)." }
        return """
        \(facts)
        Give a short English gloss for 「\(surface)」 as a whole, with its grammar folded into the \
        English (at most 8 words). For example, 食べたくない: to not want to eat; 降りそう: looks like \
        it will fall. Reply with the gloss only.
        """
    }

    // What the ⓘ beside a whole-form meaning says: where it came from and that it can be wrong.
    static func explanation(surface: String, lemmaLine: String) -> String {
        let parts = lemmaLine.components(separatedBy: " + ").map { "「\($0)」" }.joined(separator: " and ")
        return "Kioku's dictionary defines \(parts) but not 「\(surface)」 as a whole, so Apple Intelligence on this device put this meaning together from those definitions and the form the word is in. It can be wrong."
    }
}
