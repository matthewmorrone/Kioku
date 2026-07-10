import Foundation

// Breaks a derived word into its morphemes for the WordDetail "Components" section — a base word
// plus a productive affix (科学 + 的, 危険 + 性, 不 + 可能), each with its own gloss.
//
// Deliberately does NOT use the segmenter. The segmenter's whole job is to classify a word like
// その AS one unit, so asking it to break a single unit apart is using the tool against its purpose
// — it only yields a split by failing at its own task, and that split is noise (その → そ "white
// silk" + の "arrow shaft"). Instead a split must satisfy two dictionary facts:
//   • the affix is one of a CURATED set of productive derivational affixes (below), each with a
//     hand-verified gloss, and
//   • the remainder is itself a real dictionary headword.
//
// Why curated rather than "any surface JMdict tags suf/pref": a purely mechanical version was
// measured against ~85 words and mis-split ~20% — lone-kana suffixes matched atomic words
// (うわさ → うわ + さ), homograph glosses leaked in (お → 小 "small"), and lexicalized compounds
// split (真面目 → 真面 + 目). The curated set + a ≥2-char base + the headword gate drove false
// positives to zero across that battery while still decomposing the productive ~80%. Every entry
// added here should be re-checked against words that merely END in it (的: 目的; 会: 都会; 学:
// 大学) — the 2-char cases are already covered by the length guard, but 3-char lexicalizations
// (真面目) are the ones to watch. Extending the tables is the intended way to grow coverage.
extension DictionaryStore {

    // One morpheme of a breakdown: the surface, its structural role, and its dictionary gloss.
    public struct BreakdownMorpheme: Sendable, Equatable {
        public let surface: String
        public let role: String
        public let gloss: String?
    }

    // Productive derivational SUFFIXES (base + affix), with verified glosses. Longest is 2 chars.
    private static let derivationalSuffixes: [String: String] = [
        "的": "-ic; -ical; -ive", "化": "-ization; turning into", "性": "-ness; -ity; nature of",
        "感": "a feeling of; sense of", "力": "power; ability", "者": "person; -er",
        "家": "-ist; expert", "員": "member; staff", "会": "meeting; association",
        "度": "degree; extent", "用": "for use with", "製": "made of; made by",
        "費": "expense; cost", "料": "fee; charge", "語": "language of", "学": "study of; -ology",
        "式": "-style; ceremony", "界": "world of; -sphere", "型": "type; model",
        "症": "illness; -osis", "病": "disease of", "たち": "(pluralizing suffix)",
    ]

    // Productive derivational PREFIXES (affix + base), with verified glosses.
    private static let derivationalPrefixes: [String: String] = [
        "不": "un-; non-; in-", "無": "without; -less", "非": "non-; un-", "未": "not yet; un-",
        "超": "super-; ultra-", "再": "re-; again", "半": "half-; semi-", "各": "each; every",
        "全": "all; whole", "お": "(honorific prefix)", "ご": "(honorific prefix)",
    ]

    // Returns [base, suffix] or [prefix, base] when `surface` is a headword base plus a curated
    // derivational affix; nil when it isn't cleanly decomposable.
    public func affixBreakdown(for surface: String) -> [BreakdownMorpheme]? {
        let characters = Array(surface)
        // Need at least a 2-character base plus a 1-character affix; anything shorter is atomic
        // (この, その, ここ, する …) or a 2-kanji lexicalized compound (目的, 大学) and must not split.
        guard characters.count >= 3 else { return nil }

        // Suffix: base + affix. Longest affix first so 子供 + たち wins over 子供た + ち.
        for affixLength in stride(from: min(2, characters.count - 2), through: 1, by: -1) {
            let base = String(characters.prefix(characters.count - affixLength))
            let affix = String(characters.suffix(affixLength))
            if let affixGloss = Self.derivationalSuffixes[affix], let baseGloss = headwordGloss(base) {
                return [
                    BreakdownMorpheme(surface: base, role: "base word", gloss: baseGloss),
                    BreakdownMorpheme(surface: affix, role: "suffix", gloss: affixGloss),
                ]
            }
        }

        // Prefix: affix + base. Derivational prefixes here are single characters.
        let affix = String(characters.prefix(1))
        if let affixGloss = Self.derivationalPrefixes[affix] {
            let base = String(characters.dropFirst())
            // Honorific お/ご attach freely to kana (おかし, おにぎり are atomic), so restrict them to
            // kanji bases where the split is reliable (お + 名前, ご + 説明).
            let honorificOK = (affix != "お" && affix != "ご") || ScriptClassifier.containsKanji(base)
            if honorificOK, let baseGloss = headwordGloss(base) {
                return [
                    BreakdownMorpheme(surface: affix, role: "prefix", gloss: affixGloss),
                    BreakdownMorpheme(surface: base, role: "base word", gloss: baseGloss),
                ]
            }
        }

        return nil
    }

    // First gloss of `surface` when it is itself a dictionary headword (its own kanji or kana form),
    // else nil. The exact-form check keeps a deinflected or fuzzy match from passing as a clean base.
    private func headwordGloss(_ surface: String) -> String? {
        guard let entries = try? lookup(surface: surface, mode: .kanjiAndKana) else { return nil }
        for entry in entries where entry.senses.isEmpty == false {
            let isHeadword = entry.kanjiForms.contains { $0.text == surface }
                || entry.kanaForms.contains { $0.text == surface }
            if isHeadword, let gloss = entry.senses.first?.glosses.first {
                return gloss
            }
        }
        return nil
    }
}
