import Foundation

// Finer JMdict grammar distinctions than the PartOfSpeech cases keep, packed into the same UInt64
// (bits 16–32, above the enum's cases and below `unknown`) so they travel wherever POS bits already
// go — the surface map, the trie, lattice edges — with no second lookup. They are deliberately NOT
// PartOfSpeech cases: PartOfSpeech.decode and the labels shown in the UI stay as they are. The
// segmenter's transition classes (TransitionClass) are what read them: how a word connects to its
// neighbours depends on whether it is an ichidan verb or a godan one, a な-adjective or an
// い-adjective, which the coarse `verb` / `adjective` bits cannot say.
nonisolated enum PartOfSpeechDetail {
    static let ichidanVerb: UInt64 = 1 << 16       // v1, v1-s
    static let godanVerb: UInt64 = 1 << 17         // v5*
    static let suruVerb: UInt64 = 1 << 18          // vs-i, vs-s, vs-c (する itself and its kin)
    static let kuruVerb: UInt64 = 1 << 19          // vk
    static let otherVerb: UInt64 = 1 << 20         // v2*, v4*, vz, vn, vr, v-unspec
    static let auxiliaryVerb: UInt64 = 1 << 21     // aux-v
    static let auxiliaryAdjective: UInt64 = 1 << 22 // aux-adj
    static let iAdjective: UInt64 = 1 << 23        // adj-i, adj-ix
    static let naAdjective: UInt64 = 1 << 24       // adj-na
    static let noAdjective: UInt64 = 1 << 25       // adj-no
    static let prenominal: UInt64 = 1 << 26        // adj-pn
    static let taruAdjective: UInt64 = 1 << 27     // adj-t
    static let nounModifier: UInt64 = 1 << 28      // adj-f
    static let toAdverb: UInt64 = 1 << 29          // adv-to
    static let suruNoun: UInt64 = 1 << 30          // vs — a noun that takes する
    static let nounSuffix: UInt64 = 1 << 31        // n-suf
    static let nounPrefix: UInt64 = 1 << 32        // n-pref
    // on-mim — a JMdict *misc* tag, not a POS code: the startup queries pass it through alongside
    // the POS codes (and no other misc tag). Transition classes do not read it.
    static let mimetic: UInt64 = 1 << 33

    // The bits that belong to PartOfSpeech's own cases (everything below the detail bits).
    static let coarseMask: UInt64 = (1 << 16) - 1

    // Detail bits for one lowercased JMdict POS code; 0 for codes the coarse bits already cover.
    static func bits(forCode code: String) -> UInt64 {
        switch code {
        case "vs": return suruNoun
        case "vi", "vt": return 0
        case "vk": return kuruVerb
        case "aux-v": return auxiliaryVerb
        case "aux-adj": return auxiliaryAdjective
        case "adj-i", "adj-ix": return iAdjective
        case "adj-na": return naAdjective
        case "adj-no": return noAdjective
        case "adj-pn": return prenominal
        case "adj-t": return taruAdjective
        case "adj-f": return nounModifier
        case "adv-to": return toAdverb
        case "n-suf": return nounSuffix
        case "n-pref": return nounPrefix
        case "on-mim": return mimetic
        default: break
        }
        if code.hasPrefix("v1") { return ichidanVerb }
        if code.hasPrefix("v5") { return godanVerb }
        if code.hasPrefix("vs-") { return suruVerb }
        if code.hasPrefix("v") { return otherVerb }
        return 0
    }
}
