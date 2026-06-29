import Foundation

// Detects whether a saved word is a *derived* form — a base word plus a productive
// derivational affix (nominalizer さ/み, honorific prefix お/ご, pluralizer たち/ら,
// adjectival 的, suru-noun 化, address suffix さん/様) or a compound verb (食べ始める) —
// and renders a one-line description that names the actual parts, e.g.
// "Derived noun — from い-adjective 弱い + nominalizing suffix さ".
//
// JMdict tags none of this (弱さ is just "n"), so detection is rule-based off the surface
// string plus the app's existing segmentation. The analyzer is pure and synchronous: the
// caller injects a `baseResolver` that looks a candidate lemma up in the dictionary and
// returns its JMdict POS tags. This keeps the logic decoupled from DictionaryStore and
// directly unit-testable with a stub resolver.
nonisolated enum DerivationAnalyzer {

    // One morpheme in a structured breakdown. Renderers show `form` prominently and `role`
    // as a tiny caption beneath it; `gloss` is optional because the stem morpheme's gloss
    // depends on the specific base word (寂しい → "lonely", 寒い → "cold"), which the
    // analyzer's POS-only resolver can't supply — the parent word's Definition section
    // already shows that meaning, so the stem chip elides it rather than guessing.
    struct Morpheme: Equatable, Sendable {
        let form: String
        let role: String
        let gloss: String?
    }

    // A resolved derivation. `summary` is the legacy single-sentence form (used by every
    // existing rule). `morphemes`, when non-nil, opts the rule into chip-strip rendering at
    // the WordDetail header — the renderer prefers chips and ignores `summary` in that case,
    // but `summary` is still produced so accessibility readers and tests have a stable
    // textual representation of the same derivation.
    struct Result: Equatable, Sendable {
        let summary: String
        let morphemes: [Morpheme]?

        init(summary: String, morphemes: [Morpheme]? = nil) {
            self.summary = summary
            self.morphemes = morphemes
        }
    }

    // Looks a candidate lemma up; returns its JMdict POS tags (e.g. ["adj-i"]) or [] if absent.
    typealias BaseResolver = (String) -> [String]

    /// Returns a derivation description for `surface`, or nil when it isn't a recognized derivation.
    /// - Parameters:
    ///   - surface: the saved word as written, e.g. "弱さ".
    ///   - components: segmentation lemmas in order — only used to detect compound verbs.
    ///   - baseResolver: looks a lemma up, returns its POS tags.
    static func analyze(
        surface: String,
        components: [String],
        baseResolver: BaseResolver
    ) -> Result? {
        if let result = affixDerivation(surface: surface, baseResolver: baseResolver) { return result }
        if let result = compoundVerb(components: components, baseResolver: baseResolver) { return result }
        return nil
    }

    // MARK: - Affix rules (matched against the surface string)

    // Ordered so unambiguous single-kanji suffixes (的/化) win before the kana suffixes, and
    // the honorific prefix is tried last. A surface normally matches at most one rule; the
    // first match wins.
    private static func affixDerivation(surface: String, baseResolver: BaseResolver) -> Result? {
        // て-form + auxiliary verb: 生きて + ゆく, 帰って + くる, 食べて + しまう. Matched on the
        // string (not the segmentation) so it fires even for lexicalized expression entries like
        // 生きてゆく that resolve as a single dictionary unit. The te/で linker in the residual
        // stem is the gate that keeps non-compound verbs from matching.
        for (auxiliary, gloss) in teAuxiliaries where surface.hasSuffix(auxiliary) {
            let stem = String(surface.dropLast(auxiliary.count))
            if stem.count >= 2, stem.hasSuffix("て") || stem.hasSuffix("で") {
                return Result(summary: "Compound verb — \(stem) + auxiliary \(auxiliary) (\(gloss))")
            }
        }

        // Lexicalized passive verb: 生まれる ← 生む, 雇われる ← 雇う. Strip れる, map the あ-column
        // stem-final kana to its う-column godan dictionary form, and confirm that base is a verb.
        // The dictionary check keeps ordinary intransitive れる-verbs (疲れる, 流れる, 割れる) — whose
        // reconstructed base isn't a real verb — from misfiring.
        if surface.hasSuffix("れる"), surface.count >= 4 {
            let stem = surface.dropLast(2)
            if let last = stem.last, let uRow = passiveBaseEnding[last] {
                let base = String(stem.dropLast()) + String(uRow)
                if baseResolver(base).contains(where: isVerb) {
                    return Result(summary: "Passive verb — derived from \(base) (\(base) + passive ～れる)")
                }
            }
        }

        // -的 → adjectival noun ("-ic / -ical"): 科学 → 科学的
        if let (affix, stem) = suffixMatch(surface, ["的"]), stem.isEmpty == false,
           baseResolver(stem).contains(where: isNominal) {
            return Result(summary: "Adjectival noun — \(stem) + suffix \(affix) (“-ic / -ical”)")
        }

        // -化 → suru-noun ("-ization"): 自動 → 自動化
        if let (affix, stem) = suffixMatch(surface, ["化"]), stem.isEmpty == false,
           baseResolver(stem).contains(where: isNominal) {
            return Result(summary: "Suru-noun — \(stem) + suffix \(affix) (“-ization”)")
        }

        // さ / み → noun from an adjective: 弱い → 弱さ / 弱み, 静か → 静かさ.
        // Confirm by checking whether the stem (or stem+い) is an adjective in the dictionary,
        // which also tells us which class to name. This gate keeps words that merely *end* in
        // さ/み (はさみ, みさ) from misfiring.
        if let (affix, stem) = suffixMatch(surface, ["さ", "み"]), stem.isEmpty == false {
            for candidate in [stem + "い", stem] {
                if let adjectiveClass = adjectiveClass(baseResolver(candidate)) {
                    return Result(summary: "Derived noun — from \(adjectiveClass) \(candidate) + nominalizing suffix \(affix)")
                }
            }
        }

        // -がり屋 → renders as a 4-morpheme chip strip rather than a single sentence: the
        // word decomposes into adj-stem + verbalizer がる + nominalizer り + personifier 屋,
        // and the chip strip shows each piece individually. Stem+い gate confirms it's the
        // productive emotion-trait pattern; coincidental endings in 屋 (居酒屋, 本屋) fail the
        // suffix match anyway, but the い-adj check protects against fabricated -がり屋 forms
        // whose stem doesn't decompose this way.
        if let (_, stem) = suffixMatch(surface, ["がり屋"]), stem.isEmpty == false {
            let base = stem + "い"
            if baseResolver(base).contains(where: { $0.hasPrefix("adj-i") }) {
                let morphemes: [Morpheme] = [
                    Morpheme(form: "\(stem)(い)", role: "い-adj stem", gloss: nil),
                    Morpheme(form: "～がる", role: "verbalizer", gloss: "show signs of ~"),
                    Morpheme(form: "～り", role: "nominalizer", gloss: "masu-stem → noun"),
                    Morpheme(form: "屋", role: "personifier", gloss: "one who is/does habitually"),
                ]
                // Plain-text fallback for VoiceOver / accessibility readers — joined with ＋
                // so the order matches the visible chip sequence.
                let joined = morphemes.map(\.form).joined(separator: " ＋ ")
                return Result(summary: joined, morphemes: morphemes)
            }
        }

        // Unambiguous collective suffixes: 子供 → 子供たち, 私 → 私ども. Gated on a noun or pronoun
        // base so words coincidentally ending in these don't misfire.
        if let (affix, stem) = suffixMatch(surface, ["たち", "達", "ども", "共"]), stem.isEmpty == false,
           baseResolver(stem).contains(where: { isNominal($0) || isPronoun($0) }) {
            return Result(summary: "Collective noun — \(stem) + pluralizing suffix \(affix)")
        }

        // Pluralizing ら / 等: require a *pronoun* base (彼 → 彼ら, 我 → 我ら, 君 → 君ら). The bare ら is
        // homophonous with the archaic 形容動詞-forming suffix ら (清ら/きよら, 安ら), whose root is a
        // plain noun — so a nominal gate misfires there. Pronoun-only keeps the common plural
        // pronouns and drops the rare, ambiguous noun+ら forms (子供ら), which read fine unannotated.
        if let (affix, stem) = suffixMatch(surface, ["ら", "等"]), stem.isEmpty == false,
           baseResolver(stem).contains(where: isPronoun) {
            return Result(summary: "Collective noun — \(stem) + pluralizing suffix \(affix)")
        }

        // Polite address suffixes: 皆 → 皆さん, 王 → 王様. Gated on a nominal base.
        if let (affix, stem) = suffixMatch(surface, ["さん", "さま", "様", "ちゃん", "くん", "君", "氏"]), stem.isEmpty == false,
           baseResolver(stem).contains(where: isNominal) {
            return Result(summary: "Polite address — \(stem) + honorific suffix \(affix)")
        }

        // Honorific prefix お / ご / 御: 酒 → お酒, 飯 → ご飯. Require the stem to start with a
        // kanji so kana words that merely begin with お/ご (おとこ, ごみ) don't misfire — お/ご
        // is written before a kanji word in the overwhelming majority of honorific forms.
        if let (affix, stem) = prefixMatch(surface, ["御", "お", "ご"]), firstIsKanji(stem) {
            let tags = baseResolver(stem)
            if tags.isEmpty == false {
                return Result(summary: "Honorific form — prefix \(affix) + \(friendlyClass(tags)) \(stem)")
            }
        }

        return nil
    }

    // MARK: - Derivation tables

    // て-form auxiliary verbs and their roles, listed in both kana and kanji spellings since the
    // base form fed to the analyzer may use either. Order is irrelevant — the te/で gate in the
    // rule means at most one realistically matches a given surface.
    private static let teAuxiliaries: [(verb: String, gloss: String)] = [
        ("ゆく", "go on ~ing"), ("いく", "go on ~ing"), ("行く", "go on ~ing"),
        ("くる", "come to ~ / gradually ~"), ("来る", "come to ~ / gradually ~"),
        ("みる", "try ~ing"), ("見る", "try ~ing"),
        ("しまう", "~ completely / regrettably"),
        ("おく", "~ in advance"), ("置く", "~ in advance"),
        ("いる", "progressive / ongoing"), ("ある", "resultant state"),
        ("くれる", "do ~ for me"), ("もらう", "have someone ~"), ("あげる", "do ~ for someone"),
    ]

    // あ-column → う-column kana, used to reconstruct a godan dictionary form (生む) from a
    // lexicalized passive stem (生ま).
    private static let passiveBaseEnding: [Character: Character] = [
        "わ": "う", "か": "く", "が": "ぐ", "さ": "す", "た": "つ",
        "な": "ぬ", "ば": "ぶ", "ま": "む", "ら": "る", "あ": "う",
    ]

    // Grammaticalized auxiliary verbs: ichidan/godan verbs that act as aspect/voice/benefactive
    // markers when suffixed to another verb's masu-stem. Shared with WordDetailView's component
    // badge so the two stay in sync.
    static let auxiliaryVerbs: Set<String> = [
        "続ける", "始める", "終わる", "出す", "込む", "合う", "切る",
        "もらう", "あげる", "くれる", "いく", "くる", "おく", "みる",
        "しまう", "ある", "いる", "させる", "もらえる",
    ]

    // English glosses for the auxiliary role, used to annotate the compound-verb description.
    private static let auxiliaryGloss: [String: String] = [
        "続ける": "continue ~ing",
        "始める": "begin to ~",
        "終わる": "finish ~ing",
        "出す": "burst into ~ / start suddenly",
        "込む": "~ into / thoroughly",
        "合う": "~ each other",
        "切る": "~ completely",
        "もらう": "have someone ~",
        "あげる": "do ~ for someone",
        "くれる": "do ~ for me",
        "いく": "go on ~ing",
        "くる": "come to ~",
        "おく": "~ in advance",
        "みる": "try ~ing",
        "しまう": "~ completely / regrettably",
        "ある": "resultant state",
        "いる": "progressive / ongoing",
        "させる": "make / let someone ~",
        "もらえる": "can have someone ~",
    ]

    // Renders a compound-verb description when the last segmented lemma is a known auxiliary
    // verb and the leading part is itself verbal; nil otherwise.
    private static func compoundVerb(components: [String], baseResolver: BaseResolver) -> Result? {
        guard components.count >= 2, let auxiliary = components.last,
              auxiliaryVerbs.contains(auxiliary) else { return nil }
        let base = components.dropLast().joined()
        // Only a compound verb when the leading part is itself verbal.
        guard baseResolver(base).contains(where: isVerb) else { return nil }
        if let gloss = auxiliaryGloss[auxiliary] {
            return Result(summary: "Compound verb — \(base) + auxiliary \(auxiliary) (\(gloss))")
        }
        return Result(summary: "Compound verb — \(base) + auxiliary \(auxiliary)")
    }

    // MARK: - POS tag helpers

    private static func isNominal(_ tag: String) -> Bool {
        tag == "n" || tag.hasPrefix("n-") || tag == "vs" || tag.hasPrefix("vs-")
    }
    // True for the pronoun POS tag (used to admit 彼ら / 私たち as collective forms).
    private static func isPronoun(_ tag: String) -> Bool { tag == "pn" }
    // True for any verb-class tag (v1, v5*, vs-*, …) but not the unrelated "vulg" misc tag.
    private static func isVerb(_ tag: String) -> Bool { tag.hasPrefix("v") && tag != "vulg" }

    // Names the adjective class for the さ/み nominalizer rule, or nil if the tags aren't adjectival.
    private static func adjectiveClass(_ tags: [String]) -> String? {
        if tags.contains(where: { $0.hasPrefix("adj-i") }) { return "い-adjective" }
        if tags.contains("adj-na") { return "な-adjective" }
        return nil
    }

    // A friendly base-class word for the honorific-prefix description.
    private static func friendlyClass(_ tags: [String]) -> String {
        if let adjective = adjectiveClass(tags) { return adjective }
        if tags.contains(where: isVerb) { return "verb" }
        if tags.contains(where: isNominal) { return "noun" }
        return "word"
    }

    // MARK: - String matching

    private static func suffixMatch(_ surface: String, _ affixes: [String]) -> (affix: String, stem: String)? {
        for affix in affixes where surface.hasSuffix(affix) && surface.count > affix.count {
            return (affix, String(surface.dropLast(affix.count)))
        }
        return nil
    }

    // Splits a leading affix off the surface, returning the affix and the remaining stem, or nil.
    private static func prefixMatch(_ surface: String, _ affixes: [String]) -> (affix: String, stem: String)? {
        for affix in affixes where surface.hasPrefix(affix) && surface.count > affix.count {
            return (affix, String(surface.dropFirst(affix.count)))
        }
        return nil
    }

    // True when the string's first character is a CJK ideograph — gates the honorific prefix rule.
    private static func firstIsKanji(_ s: String) -> Bool {
        guard let scalar = s.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
    }
}
