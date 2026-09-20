import Foundation

// Names the word class a lattice edge belongs to for the path search's transition costs
// (SegmenterTransitionTable). The table is counted from gold sentences with THIS code, so the
// training run and the running segmenter cannot disagree about what class a word is.
//
// A class name is one of:
//   "w:は"      — the word itself, for the common function words the table lists
//   "v5:て"     — a grammar tag plus the surface's last character, for anything that conjugates:
//                 what may follow 書いて differs from what may follow 書く or 書いた
//   "adj-na"    — a grammar tag alone, for everything else
//   "BOUNDARY"  — text the dictionary does not cover, and the start and end of the text
// Sixteen coarse classes were tried first and measured no gain at any weight: a class has to be
// this fine before "B after A" says anything the word costs don't already.
nonisolated enum TransitionClass {
    static let boundary = "BOUNDARY"

    // The grammar tag for a packed POS bitfield. A surface's bits are the union over every entry
    // spelled that way (が is particle + conjunction), so the first match in this order wins:
    // function words before content words, because a surface that CAN be a particle nearly always
    // is one in running text; expressions next, because a phrase entry behaves as a unit whatever
    // its head word is.
    static func tag(partOfSpeech bits: UInt64) -> String {
        if PartOfSpeech.isParticle(bits) { return "prt" }
        if PartOfSpeech.isCopula(bits) { return "cop" }
        if bits & PartOfSpeechDetail.auxiliaryVerb != 0 { return "aux-v" }
        if bits & PartOfSpeechDetail.auxiliaryAdjective != 0 { return "aux-adj" }
        if PartOfSpeech.isAuxiliary(bits) { return "aux" }
        if PartOfSpeech.isConjunction(bits) { return "conj" }
        let verbDetail = PartOfSpeechDetail.ichidanVerb | PartOfSpeechDetail.godanVerb | PartOfSpeechDetail.suruVerb
            | PartOfSpeechDetail.kuruVerb | PartOfSpeechDetail.otherVerb
        if PartOfSpeech.isExpression(bits) {
            if bits & verbDetail != 0 { return "exp-v" }
            if bits & PartOfSpeechDetail.iAdjective != 0 { return "exp-adj" }
            return "exp"
        }
        if bits & PartOfSpeechDetail.ichidanVerb != 0 { return "v1" }
        if bits & PartOfSpeechDetail.godanVerb != 0 { return "v5" }
        if bits & PartOfSpeechDetail.suruVerb != 0 { return "vs-i" }
        if bits & PartOfSpeechDetail.kuruVerb != 0 { return "vk" }
        if bits & PartOfSpeechDetail.otherVerb != 0 { return "v-other" }
        if bits & PartOfSpeechDetail.iAdjective != 0 { return "adj-i" }
        if bits & PartOfSpeechDetail.naAdjective != 0 { return "adj-na" }
        if bits & PartOfSpeechDetail.noAdjective != 0 { return "adj-no" }
        if bits & PartOfSpeechDetail.prenominal != 0 { return "adj-pn" }
        if bits & PartOfSpeechDetail.taruAdjective != 0 { return "adj-t" }
        if bits & PartOfSpeechDetail.nounModifier != 0 { return "adj-f" }
        if PartOfSpeech.isAdverb(bits) { return "adv" }
        if bits & PartOfSpeechDetail.toAdverb != 0 { return "adv-to" }
        if PartOfSpeech.isProperNoun(bits) || PartOfSpeech.isPronoun(bits) { return "pn" }
        if bits & PartOfSpeechDetail.nounSuffix != 0 { return "n-suf" }
        if PartOfSpeech.isSuffix(bits) { return "suf" }
        if bits & PartOfSpeechDetail.nounPrefix != 0 { return "n-pref" }
        if PartOfSpeech.isPrefix(bits) { return "pref" }
        if PartOfSpeech.isCounter(bits) { return "ctr" }
        if PartOfSpeech.isNumeric(bits) { return "num" }
        if PartOfSpeech.isInterjection(bits) { return "int" }
        if PartOfSpeech.isNoun(bits) { return bits & PartOfSpeechDetail.suruNoun != 0 ? "n-vs" : "n" }
        return "unc"
    }

    // True for tags whose words conjugate, so the class also carries the surface's ending.
    static func conjugates(_ tag: String) -> Bool {
        tag.hasPrefix("v") || tag.hasPrefix("aux") || tag == "adj-i" || tag == "exp-v" || tag == "exp-adj" || tag == "cop"
    }

    // The full class name for a dictionary word: `surface` as written, `bits` as the lattice
    // carries them (LatticeEdge.partOfSpeech), `lexical` the words the table gives a class of their own.
    static func name(surface: String, partOfSpeech bits: UInt64, lexical: Set<String>) -> String {
        if lexical.contains(surface) { return "w:" + surface }
        let tag = tag(partOfSpeech: bits)
        guard conjugates(tag), let last = surface.last else { return tag }
        return tag + ":" + String(last)
    }

    // The class to fall back to when the table has no evidence about the full one: the tag
    // without its ending. A word with a class of its own has nothing coarser.
    static func coarse(_ name: String) -> String {
        guard name.hasPrefix("w:") == false, let colon = name.firstIndex(of: ":") else { return name }
        return String(name[..<colon])
    }
}
