import Foundation

public enum PartOfSpeech: UInt8, CaseIterable {
    case noun = 0
    case pronoun = 1
    case adjective = 2
    case verb = 3
    case auxiliary = 4
    case particle = 5
    case adverb = 6
    case interjection = 7
    case conjunction = 8
    case counter = 9
    case numeric = 10
    case prefix = 11
    case suffix = 12
    case expression = 13
    case copula = 14
    case properNoun = 15
    case unknown = 63

    // Returns this part-of-speech as a compact bit flag.
    public nonisolated var bit: UInt64 {
        UInt64(1) << rawValue
    }

    // Returns a stable short label for debug rendering.
    public nonisolated var label: String {
        switch self {
        case .noun: return "noun"
        case .pronoun: return "pronoun"
        case .adjective: return "adjective"
        case .verb: return "verb"
        case .auxiliary: return "auxiliary"
        case .particle: return "particle"
        case .adverb: return "adverb"
        case .interjection: return "interjection"
        case .conjunction: return "conjunction"
        case .counter: return "counter"
        case .numeric: return "numeric"
        case .prefix: return "prefix"
        case .suffix: return "suffix"
        case .expression: return "expression"
        case .copula: return "copula"
        case .properNoun: return "proper-noun"
        case .unknown: return "unknown"
        }
    }

    // Decodes one combined bitset back into ordered part-of-speech labels.
    public nonisolated static func decode(bits: UInt64) -> [PartOfSpeech] {
        if bits == 0 { return [] }
        return PartOfSpeech.allCases.filter { (bits & $0.bit) != 0 }
    }

    // Maps one raw JMdict-like POS payload into compact bit flags.
    public nonisolated static func bits(from rawValue: String?) -> UInt64 {
        guard let rawValue else { return 0 }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        var bits: UInt64 = 0
        for rawCode in trimmed.split(separator: ",") {
            let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if code.isEmpty { continue }
            if code == "n"              { bits |= PartOfSpeech.noun.bit; continue }
            if code == "n-suf"          { bits |= PartOfSpeech.noun.bit | PartOfSpeech.suffix.bit; continue }
            if code == "n-pref"         { bits |= PartOfSpeech.noun.bit | PartOfSpeech.prefix.bit; continue }
            if code == "pn"             { bits |= PartOfSpeech.properNoun.bit; continue }
            if code == "adj-i" || code == "adj-na" || code == "adj-no" || code == "adj-t" {
                bits |= PartOfSpeech.adjective.bit; continue
            }
            if code.hasPrefix("v")      { bits |= PartOfSpeech.verb.bit; continue }
            if code == "aux"            { bits |= PartOfSpeech.auxiliary.bit; continue }
            if code == "prt"            { bits |= PartOfSpeech.particle.bit; continue }
            if code == "adv"            { bits |= PartOfSpeech.adverb.bit; continue }
            if code == "int"            { bits |= PartOfSpeech.interjection.bit; continue }
            if code == "conj"           { bits |= PartOfSpeech.conjunction.bit; continue }
            if code == "ctr"            { bits |= PartOfSpeech.counter.bit; continue }
            if code == "num"            { bits |= PartOfSpeech.numeric.bit; continue }
            if code == "pref"           { bits |= PartOfSpeech.prefix.bit; continue }
            if code == "suf"            { bits |= PartOfSpeech.suffix.bit; continue }
            if code == "exp"            { bits |= PartOfSpeech.expression.bit; continue }
            if code == "cop"            { bits |= PartOfSpeech.copula.bit; continue }
            if code == "pron"           { bits |= PartOfSpeech.pronoun.bit; continue }
            if code == "proper"         { bits |= PartOfSpeech.properNoun.bit; continue }
        }
        return bits == 0 ? PartOfSpeech.unknown.bit : bits
    }

    // Bit-check helpers — nonisolated so they're callable from any concurrency context.
    // Returns true when the particle bit is set on the packed POS value.
    public nonisolated static func isParticle(_ bits: UInt64) -> Bool  { (bits & PartOfSpeech.particle.bit) != 0 }
    // Returns true when the noun bit is set on the packed POS value.
    public nonisolated static func isNoun(_ bits: UInt64) -> Bool      { (bits & PartOfSpeech.noun.bit) != 0 }
    // Returns true when the adjective bit is set on the packed POS value.
    public nonisolated static func isAdjective(_ bits: UInt64) -> Bool { (bits & PartOfSpeech.adjective.bit) != 0 }
    // Returns true when the verb bit is set on the packed POS value.
    public nonisolated static func isVerb(_ bits: UInt64) -> Bool      { (bits & PartOfSpeech.verb.bit) != 0 }
    // Returns true when the auxiliary bit is set on the packed POS value.
    public nonisolated static func isAuxiliary(_ bits: UInt64) -> Bool { (bits & PartOfSpeech.auxiliary.bit) != 0 }
    // Returns true when the prefix bit is set on the packed POS value.
    public nonisolated static func isPrefix(_ bits: UInt64) -> Bool    { (bits & PartOfSpeech.prefix.bit) != 0 }
    // Returns true when the counter bit is set on the packed POS value.
    public nonisolated static func isCounter(_ bits: UInt64) -> Bool   { (bits & PartOfSpeech.counter.bit) != 0 }
    // Returns true when the adverb bit is set on the packed POS value.
    public nonisolated static func isAdverb(_ bits: UInt64) -> Bool    { (bits & PartOfSpeech.adverb.bit) != 0 }
    // Returns true when the conjunction bit is set on the packed POS value.
    public nonisolated static func isConjunction(_ bits: UInt64) -> Bool { (bits & PartOfSpeech.conjunction.bit) != 0 }
    // Returns true when the suffix bit is set on the packed POS value.
    public nonisolated static func isSuffix(_ bits: UInt64) -> Bool    { (bits & PartOfSpeech.suffix.bit) != 0 }
    // Returns true when the copula bit is set on the packed POS value.
    public nonisolated static func isCopula(_ bits: UInt64) -> Bool    { (bits & PartOfSpeech.copula.bit) != 0 }
    // Returns true when the numeric bit is set on the packed POS value.
    public nonisolated static func isNumeric(_ bits: UInt64) -> Bool   { (bits & PartOfSpeech.numeric.bit) != 0 }
    // Returns true when the pronoun bit is set on the packed POS value.
    public nonisolated static func isPronoun(_ bits: UInt64) -> Bool   { (bits & PartOfSpeech.pronoun.bit) != 0 }
    // Returns true when the proper-noun bit is set on the packed POS value.
    public nonisolated static func isProperNoun(_ bits: UInt64) -> Bool { (bits & PartOfSpeech.properNoun.bit) != 0 }
    // Returns true when the interjection bit is set on the packed POS value.
    public nonisolated static func isInterjection(_ bits: UInt64) -> Bool { (bits & PartOfSpeech.interjection.bit) != 0 }
    // Returns true when the expression bit is set on the packed POS value.
    public nonisolated static func isExpression(_ bits: UInt64) -> Bool { (bits & PartOfSpeech.expression.bit) != 0 }
}
