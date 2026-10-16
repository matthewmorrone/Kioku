import Foundation

// Maps JMdict POS tags onto the grammar names deinflection rules end on (rulesOut: v1, v5, vk, vs,
// adj-i, and the classical nidan v2s/v2k), so a chain's ending can be checked against the entries a
// lemma spelling covers. いる is both 居る (v1) and 要る (v5); only the godan one can be what いった
// conjugates.
nonisolated enum ConjugationClass {
    // The rule grammar a single JMdict POS tag conjugates as, or nil when it doesn't conjugate.
    // Nidan tags name their row and kind (v2d-s: ダ行 shimo-nidan, 出づ); the rules only need the kind.
    static func grammar(forPOSTag tag: String) -> String? {
        let tag = tag.trimmingCharacters(in: .whitespaces)
        if tag.hasPrefix("v2"), tag.hasSuffix("-s") { return "v2s" }
        if tag.hasPrefix("v2"), tag.hasSuffix("-k") { return "v2k" }
        if tag.hasPrefix("v1") || tag == "vz" { return "v1" }
        if tag.hasPrefix("v5") { return "v5" }
        if tag == "vk" { return "vk" }
        if tag.hasPrefix("vs") { return "vs" }
        if tag == "adj-i" || tag == "adj-ix" { return "adj-i" }
        return nil
    }

    // The rule grammars grammar(forPOSTag:) maps tags onto. A chain ending on any other grammar (the
    // plural suffix's noun, 星たち → 星) says nothing about how its lemma conjugates.
    static let conjugationGrammars: Set<String> = ["v1", "v5", "vk", "vs", "adj-i", "v2s", "v2k"]

    // The POS detail bit (PartOfSpeechDetail) a word must carry for a chain ending on `grammar` to
    // reach it, where the segmenter's coarse verb bit can't tell: a nidan rule (くる → く, する → す)
    // reaches only a word JMdict tags v2*, never 来 or 酢. Nil for the modern grammars.
    static func requiredDetailBit(forGrammar grammar: String) -> UInt64? {
        grammar == "v2s" || grammar == "v2k" ? PartOfSpeechDetail.otherVerb : nil
    }

    // The tags among `posTags` that conjugate, kept exact (v5k-s, v1-s, v5aru) rather than collapsed to
    // a rule grammar: two words sharing one inflect identically, which a shared grammar doesn't promise
    // (行く is v5k-s, so it never takes 書く's いた).
    static func conjugatingTags(in posTags: some Sequence<String>) -> Set<String> {
        Set(posTags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { grammar(forPOSTag: $0) != nil })
    }

    // Every rule grammar the comma-joined POS strings of an entry's senses conjugate as.
    static func grammars(forPOSStrings posStrings: [String]) -> Set<String> {
        Set(posStrings.flatMap { $0.split(separator: ",") }.compactMap { grammar(forPOSTag: String($0)) })
    }
}
