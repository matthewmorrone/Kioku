import Foundation

// Verb class for Japanese verbs. Pure case enum — may live in the same file as VerbConjugator.
enum VerbClass: Hashable, Sendable {
    case ichidan
    case godan
    case suru
    case kuru
}

// Internal helper for selecting the correct godan stem column.
// Pure case enum — may live in the same file as VerbConjugator.
enum GodanRow { case a, i, e, o }

// Generates conjugation paradigm groups for Japanese verbs.
// Each group corresponds to one card in ConjugationSheetView.
// Port and expansion of archive/kyouku/kyouku/VerbConjugator.swift.
struct VerbConjugator {

    // Detects verb class from JMdict POS tag strings (e.g. "v1", "v5s", "vk", "vs-i").
    // "v1-s" (くれる class) is matched by prefix, not exact match, so it lands in .ichidan
    // alongside plain "v1" — the imperative irregularity is handled inside ichidanGroups.
    // "vz" (-ずる verbs, e.g. 論ずる) also maps to .ichidan since they conjugate like the
    // corresponding -じる verb everywhere except the dictionary form.
    // Returns nil when no verb POS tag is found.
    static func detectVerbClass(fromJMDictPosTags tags: [String]) -> VerbClass? {
        let normalized = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if normalized.contains("vk") { return .kuru }
        if normalized.contains(where: { $0.hasPrefix("vs") }) { return .suru }
        if normalized.contains(where: { $0.hasPrefix("v1") }) || normalized.contains("vz") { return .ichidan }
        if normalized.contains(where: { $0.hasPrefix("v5") }) { return .godan }
        return nil
    }

    // Returns all conjugation groups for display in ConjugationSheetView.
    static func conjugationGroups(for dictionaryForm: String, verbClass: VerbClass) -> [ConjugationGroup] {
        let base = dictionaryForm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard base.isEmpty == false else { return [] }
        switch verbClass {
        case .ichidan: return ichidanGroups(base)
        case .godan:   return godanGroups(base)
        case .suru:    return suruGroups(base)
        case .kuru:    return kuruGroups(base)
        }
    }

    // Returns the 3 key forms shown inline in WordDetailView before the "All conjugations" row.
    // Always: te-form, negative, past — in that order.
    static func keyForms(for dictionaryForm: String, verbClass: VerbClass) -> [ConjugationRow] {
        keyForms(from: conjugationGroups(for: dictionaryForm, verbClass: verbClass))
    }

    // Picks the te-form, negative, and past rows (in that order) out of any conjugation
    // paradigm's groups. Shared by keyForms(for:verbClass:) and adjectiveKeyForms(for:), which
    // differ only in which group builder produced `groups`.
    private static func keyForms(from groups: [ConjugationGroup]) -> [ConjugationRow] {
        let teForm   = groups.first(where: { $0.name == "Te-form"  })?.rows.first
        let negative = groups.first(where: { $0.name == "Plain"    })?.rows.first(where: { $0.label == "Negative" })
        let past     = groups.first(where: { $0.name == "Plain"    })?.rows.first(where: { $0.label == "Past" })
        return [teForm, negative, past].compactMap { $0 }
    }

    // True when the POS tags mark an i-adjective (adj-i / adj-ix), which conjugates like 欲しい.
    // aux-adj alone (without adj-i) is not enough — those entries don't take the い-adjective
    // paradigm on their own dictionary form.
    static func isIAdjective(fromJMDictPosTags tags: [String]) -> Bool {
        let normalized = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return normalized.contains("adj-i") || normalized.contains("adj-ix")
    }

    // Conjugation groups for an i-adjective dictionary form (ends in い).
    static func adjectiveConjugationGroups(for dictionaryForm: String) -> [ConjugationGroup] {
        adjectiveGroups(dictionaryForm.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // Key inline forms for an i-adjective: te-form, negative, past — mirroring keyForms(for:verbClass:).
    static func adjectiveKeyForms(for dictionaryForm: String) -> [ConjugationRow] {
        keyForms(from: adjectiveConjugationGroups(for: dictionaryForm))
    }
}

// MARK: - Group builders

private extension VerbConjugator {

    // Builds a full-paradigm group with 4 rows: form / negative / past / negative past.
    static func fullGroup(name: String, form: String, negative: String, past: String, negativePast: String) -> ConjugationGroup {
        ConjugationGroup(name: name, rows: [
            ConjugationRow(label: name,            surface: form),
            ConjugationRow(label: "Negative",      surface: negative),
            ConjugationRow(label: "Past",          surface: past),
            ConjugationRow(label: "Negative past", surface: negativePast),
        ])
    }

    // Volition (食べよう, "let's eat / I'll eat") and its negative まい. Volition has no past:
    // 食べたろう is past conjecture and lives in presumptiveGroup instead.
    static func volitionalGroup(volitional: String, negative: String) -> ConjugationGroup {
        ConjugationGroup(name: "Volitional", rows: [
            ConjugationRow(label: "Volitional",     surface: volitional),
            ConjugationRow(label: "Negative (まい)", surface: negative),
        ])
    }

    // Conjecture ("probably…") built on the plain forms: modern だろう on all four, plus the literary
    // たろう past (食べたろう, 読んだろう) that used to be mislabelled as a past volitional.
    static func presumptiveGroup(plain: String, negative: String, past: String, negativePast: String) -> ConjugationGroup {
        ConjugationGroup(name: "Presumptive", rows: [
            ConjugationRow(label: "Presumptive",              surface: plain + "だろう"),
            ConjugationRow(label: "Negative",                 surface: negative + "だろう"),
            ConjugationRow(label: "Past",                     surface: past + "だろう"),
            ConjugationRow(label: "Negative past",            surface: negativePast + "だろう"),
            ConjugationRow(label: "Past (literary)",          surface: past + "ろう"),
            ConjugationRow(label: "Negative past (literary)", surface: negativePast + "ろう"),
        ])
    }

    // The ば and たら conditionals, each labelled by its construction. たら is built on the た-form
    // but is not a past-tense condition (食べたら = "if/when (I) eat"), so it is never labelled "Past".
    static func conditionalGroup(ba: String, negativeBa: String, past: String, negativePast: String) -> ConjugationGroup {
        ConjugationGroup(name: "Conditional", rows: [
            ConjugationRow(label: "Conditional (ば)",  surface: ba),
            ConjugationRow(label: "Negative (ば)",     surface: negativeBa),
            ConjugationRow(label: "Conditional (たら)", surface: past + "ら"),
            ConjugationRow(label: "Negative (たら)",    surface: negativePast + "ら"),
        ])
    }

    // The connective "without doing" constructions only: ないで on the modern negative, ずに on the
    // negative-auxiliary stem. That stem is the verb's own 未然形 (あらずに), never ある's suppletive ない.
    static func withoutDoingGroup(negative: String, negativeStem: String) -> ConjugationGroup {
        ConjugationGroup(name: "Without doing", rows: [
            ConjugationRow(label: "Without doing (ないで)", surface: negative + "で"),
            ConjugationRow(label: "Without doing (ずに)",  surface: negativeStem + "ずに"),
        ])
    }

    // Bare negatives outside the ない paradigm, kept apart from the connectives above: literary ず and
    // ぬ, and the contracted ん. ある has no ん row (あらん reads as the classical volitional あらむ).
    static func otherNegativesGroup(negativeStem: String, hasContraction: Bool = true) -> ConjugationGroup {
        var rows = [
            ConjugationRow(label: "Literary (ず)", surface: negativeStem + "ず"),
            ConjugationRow(label: "Literary (ぬ)", surface: negativeStem + "ぬ"),
        ]
        if hasContraction {
            rows.append(ConjugationRow(label: "Contracted (ん)", surface: negativeStem + "ん"))
        }
        return ConjugationGroup(name: "Other negatives", rows: rows)
    }

    // MARK: I-adjective

    // Produces the paradigm for i-adjectives (dictionary form ends in い), e.g. 欲しい, 高い, 良い.
    // いい is irregular: every inflected form uses the よ stem (よく, よかった…) while the present
    // form stays いい. 良い and all regular i-adjectives inflect off the stem (form minus final い).
    static func adjectiveGroups(_ base: String) -> [ConjugationGroup] {
        guard base.hasSuffix("い"), base.count >= 2 else { return [] }
        let stem = (base == "いい") ? "よ" : String(base.dropLast())

        return [
            fullGroup(
                name: "Plain",
                form: base,
                negative: stem + "くない",
                past: stem + "かった",
                negativePast: stem + "くなかった"
            ),
            fullGroup(
                name: "Polite",
                form: base + "です",
                negative: stem + "くないです",
                past: stem + "かったです",
                negativePast: stem + "くなかったです"
            ),
            ConjugationGroup(name: "Te-form", rows: [
                ConjugationRow(label: "Te-form", surface: stem + "くて"),
            ]),
            ConjugationGroup(name: "Conditional", rows: [
                ConjugationRow(label: "Conditional (ば)",  surface: stem + "ければ"),
                ConjugationRow(label: "Conditional (たら)", surface: stem + "かったら"),
            ]),
            ConjugationGroup(name: "Adverbial", rows: [
                ConjugationRow(label: "Adverbial", surface: stem + "く"),
            ]),
            ConjugationGroup(name: "Presumptive", rows: [
                ConjugationRow(label: "Plain",  surface: base + "だろう"),
                ConjugationRow(label: "Polite", surface: base + "でしょう"),
            ]),
        ]
    }

    // MARK: Ichidan

    // Produces the full paradigm for ichidan (Group II / ru-verb) verbs.
    // -ずる verbs (論ずる, 命ずる, ...) inflect exactly like their -じる twin everywhere except
    // the dictionary form itself, so their stem is built off "じ" rather than dropping just る.
    // くれる (and 呉れる/てくれる compounds) take an irregular imperative — see isKureruClass.
    static func ichidanGroups(_ base: String) -> [ConjugationGroup] {
        guard base.hasSuffix("る"), base.count >= 2 else { return [] }
        let stem = base.hasSuffix("ずる") ? String(base.dropLast(2)) + "じ" : String(base.dropLast())
        let imperative = isKureruClass(base) ? stem : stem + "ろ"

        return [
            fullGroup(
                name: "Plain",
                form: base,
                negative: stem + "ない",
                past: stem + "た",
                negativePast: stem + "なかった"
            ),
            fullGroup(
                name: "Polite",
                form: stem + "ます",
                negative: stem + "ません",
                past: stem + "ました",
                negativePast: stem + "ませんでした"
            ),
            fullGroup(
                name: "Progressive",
                form: stem + "ている",
                negative: stem + "ていない",
                past: stem + "ていた",
                negativePast: stem + "ていなかった"
            ),
            fullGroup(
                name: "Desire",
                form: stem + "たい",
                negative: stem + "たくない",
                past: stem + "たかった",
                negativePast: stem + "たくなかった"
            ),
            volitionalGroup(volitional: stem + "よう", negative: base + "まい"),
            presumptiveGroup(plain: base, negative: stem + "ない", past: stem + "た", negativePast: stem + "なかった"),
            fullGroup(
                name: "Potential",
                form: stem + "られる",
                negative: stem + "られない",
                past: stem + "られた",
                negativePast: stem + "られなかった"
            ),
            fullGroup(
                name: "Passive",
                form: stem + "られる",
                negative: stem + "られない",
                past: stem + "られた",
                negativePast: stem + "られなかった"
            ),
            fullGroup(
                name: "Causative",
                form: stem + "させる",
                negative: stem + "させない",
                past: stem + "させた",
                negativePast: stem + "させなかった"
            ),
            fullGroup(
                name: "Causative-passive",
                form: stem + "させられる",
                negative: stem + "させられない",
                past: stem + "させられた",
                negativePast: stem + "させられなかった"
            ),
            conditionalGroup(ba: stem + "れば", negativeBa: stem + "なければ", past: stem + "た", negativePast: stem + "なかった"),
            ConjugationGroup(name: "Te-form", rows: [
                ConjugationRow(label: "Te-form",   surface: stem + "て"),
                ConjugationRow(label: "Tari-form", surface: stem + "たり"),
            ]),
            withoutDoingGroup(negative: stem + "ない", negativeStem: stem),
            otherNegativesGroup(negativeStem: stem),
            ConjugationGroup(name: "Imperative", rows: [
                ConjugationRow(label: "Imperative", surface: imperative),
                ConjugationRow(label: "Negative",   surface: base + "な"),
            ]),
            ConjugationGroup(name: "Noun form", rows: [
                ConjugationRow(label: "Noun form", surface: stem),
            ]),
        ]
    }

    // くれる's imperative is the bare stem くれ, not the regular ichidan くれろ — also covers
    // 呉れる and auxiliary use (Vて + くれる).
    static func isKureruClass(_ base: String) -> Bool {
        base.hasSuffix("くれる") || base.hasSuffix("呉れる")
    }

    // MARK: Godan

    // Produces the full paradigm for godan (Group I / u-verb) verbs.
    // Two irregularities are folded in here rather than as separate VerbClass cases, matching
    // the existing 行く-in-godanTeTa style:
    //  - ある/在る/有る is suppletive in the negative: あらない isn't a word, so its plain
    //    negative-family forms use the separate lexeme ない instead (see isAruIrregular /
    //    negBase below).
    //  - いらっしゃる・おっしゃる・くださる・なさる・ござる (JMdict "v5aru") take an い-stem for
    //    ます/たい/noun-form and an い imperative, not the regular り/れ columns.
    static func godanGroups(_ base: String) -> [ConjugationGroup] {
        guard let last = base.last else { return [] }
        let lastKana = String(last)
        let stem = String(base.dropLast())

        guard
            let iStem = godanStem(lastKana: lastKana, row: .i),
            let aStem = godanStem(lastKana: lastKana, row: .a),
            let eStem = godanStem(lastKana: lastKana, row: .e),
            let oStem = godanStem(lastKana: lastKana, row: .o)
        else { return [] }

        let teTa = godanTeTa(base: base, lastKana: lastKana, stem: stem)
        let te = teTa.te
        let ta = teTa.ta

        // ある's short-form negative is suppletive (ない, not あらない); negBase is the prefix
        // those forms build on, so it collapses to "" instead of stem+aStem for ある alone.
        // The ず/ぬ auxiliaries are not suppletive and keep the regular stem (あらずに, あらぬ).
        let negBase = isAruIrregular(base) ? "" : stem + aStem

        // い-stem/imperative override for the honorific -aru verbs (v5aru); regular godan verbs
        // keep their normal り/れ columns.
        let honorificStem = isHonorificGodanAru(base) ? "い" : iStem
        let imperative = isHonorificGodanAru(base) ? stem + "い" : stem + eStem

        return [
            fullGroup(
                name: "Plain",
                form: base,
                negative: negBase + "ない",
                past: ta,
                negativePast: negBase + "なかった"
            ),
            fullGroup(
                name: "Polite",
                form: stem + honorificStem + "ます",
                negative: stem + honorificStem + "ません",
                past: stem + honorificStem + "ました",
                negativePast: stem + honorificStem + "ませんでした"
            ),
            fullGroup(
                name: "Progressive",
                form: te + "いる",
                negative: te + "いない",
                past: te + "いた",
                negativePast: te + "いなかった"
            ),
            fullGroup(
                name: "Desire",
                form: stem + honorificStem + "たい",
                negative: stem + honorificStem + "たくない",
                past: stem + honorificStem + "たかった",
                negativePast: stem + honorificStem + "たくなかった"
            ),
            volitionalGroup(volitional: stem + oStem + "う", negative: base + "まい"),
            presumptiveGroup(plain: base, negative: negBase + "ない", past: ta, negativePast: negBase + "なかった"),
            fullGroup(
                name: "Potential",
                form: stem + eStem + "る",
                negative: stem + eStem + "ない",
                past: stem + eStem + "た",
                negativePast: stem + eStem + "なかった"
            ),
            fullGroup(
                name: "Passive",
                form: stem + aStem + "れる",
                negative: stem + aStem + "れない",
                past: stem + aStem + "れた",
                negativePast: stem + aStem + "れなかった"
            ),
            fullGroup(
                name: "Causative",
                form: stem + aStem + "せる",
                negative: stem + aStem + "せない",
                past: stem + aStem + "せた",
                negativePast: stem + aStem + "せなかった"
            ),
            fullGroup(
                name: "Causative-passive",
                form: stem + aStem + "せられる",
                negative: stem + aStem + "せられない",
                past: stem + aStem + "せられた",
                negativePast: stem + aStem + "せられなかった"
            ),
            conditionalGroup(ba: stem + eStem + "ば", negativeBa: negBase + "なければ", past: ta, negativePast: negBase + "なかった"),
            ConjugationGroup(name: "Te-form", rows: [
                ConjugationRow(label: "Te-form",   surface: te),
                ConjugationRow(label: "Tari-form", surface: ta + "り"),
            ]),
            withoutDoingGroup(negative: negBase + "ない", negativeStem: stem + aStem),
            otherNegativesGroup(negativeStem: stem + aStem, hasContraction: isAruIrregular(base) == false),
            ConjugationGroup(name: "Imperative", rows: [
                ConjugationRow(label: "Imperative", surface: imperative),
                ConjugationRow(label: "Negative",   surface: base + "な"),
            ]),
            ConjugationGroup(name: "Noun form", rows: [
                ConjugationRow(label: "Noun form", surface: stem + honorificStem),
            ]),
        ]
    }

    // ある/在る/有る is suppletive in the negative: あらない is not a word, so plain negation
    // is expressed by the separate lexeme ない instead of a form derived from ある's own stem
    // (JMdict tags this verb "v5r-i", "irregular ru-verb").
    static func isAruIrregular(_ base: String) -> Bool {
        base == "ある" || base == "在る" || base == "有る"
    }

    // The honorific/humble "v5aru" verbs use an い-row renyou stem and い imperative instead of
    // the regular godan り/れ columns (いらっしゃいます, ください, not いらっしゃります/いらっしゃれ).
    static func isHonorificGodanAru(_ base: String) -> Bool {
        ["いらっしゃる", "おっしゃる", "くださる", "なさる", "ござる"].contains(where: { base.hasSuffix($0) })
    }

    // MARK: Suru

    // Produces the full paradigm for suru verbs — both the bare verb (する) and
    // suru-compounds (e.g. 勉強する). base.count >= 2 (not > 2) so する itself, whose
    // prefix is legitimately "", still conjugates instead of being rejected as too short.
    static func suruGroups(_ base: String) -> [ConjugationGroup] {
        guard base.hasSuffix("する"), base.count >= 2 else { return [] }
        let prefix = String(base.dropLast(2))

        return [
            fullGroup(
                name: "Plain",
                form: base,
                negative: prefix + "しない",
                past: prefix + "した",
                negativePast: prefix + "しなかった"
            ),
            fullGroup(
                name: "Polite",
                form: prefix + "します",
                negative: prefix + "しません",
                past: prefix + "しました",
                negativePast: prefix + "しませんでした"
            ),
            fullGroup(
                name: "Progressive",
                form: prefix + "している",
                negative: prefix + "していない",
                past: prefix + "していた",
                negativePast: prefix + "していなかった"
            ),
            fullGroup(
                name: "Desire",
                form: prefix + "したい",
                negative: prefix + "したくない",
                past: prefix + "したかった",
                negativePast: prefix + "したくなかった"
            ),
            volitionalGroup(volitional: prefix + "しよう", negative: prefix + "するまい"),
            presumptiveGroup(plain: base, negative: prefix + "しない", past: prefix + "した", negativePast: prefix + "しなかった"),
            fullGroup(
                name: "Potential",
                form: prefix + "できる",
                negative: prefix + "できない",
                past: prefix + "できた",
                negativePast: prefix + "できなかった"
            ),
            fullGroup(
                name: "Passive",
                form: prefix + "される",
                negative: prefix + "されない",
                past: prefix + "された",
                negativePast: prefix + "されなかった"
            ),
            fullGroup(
                name: "Causative",
                form: prefix + "させる",
                negative: prefix + "させない",
                past: prefix + "させた",
                negativePast: prefix + "させなかった"
            ),
            fullGroup(
                name: "Causative-passive",
                form: prefix + "させられる",
                negative: prefix + "させられない",
                past: prefix + "させられた",
                negativePast: prefix + "させられなかった"
            ),
            conditionalGroup(ba: prefix + "すれば", negativeBa: prefix + "しなければ", past: prefix + "した", negativePast: prefix + "しなかった"),
            ConjugationGroup(name: "Te-form", rows: [
                ConjugationRow(label: "Te-form",   surface: prefix + "して"),
                ConjugationRow(label: "Tari-form", surface: prefix + "したり"),
            ]),
            withoutDoingGroup(negative: prefix + "しない", negativeStem: prefix + "せ"),
            otherNegativesGroup(negativeStem: prefix + "せ"),
            ConjugationGroup(name: "Imperative", rows: [
                ConjugationRow(label: "Imperative",       surface: prefix + "しろ"),
                ConjugationRow(label: "Imperative (alt)", surface: prefix + "せよ"),
                ConjugationRow(label: "Negative",         surface: base + "な"),
            ]),
            ConjugationGroup(name: "Noun form", rows: [
                ConjugationRow(label: "Noun form", surface: prefix + "し"),
            ]),
        ]
    }

    // MARK: Kuru

    // Produces the full paradigm for kuru (来る / くる), handling both kanji and kana spellings.
    static func kuruGroups(_ base: String) -> [ConjugationGroup] {
        // Kana spelling: くる
        if base.hasSuffix("くる") {
            let prefix = String(base.dropLast(2))
            return [
                fullGroup(name: "Plain",      form: base,              negative: prefix + "こない",       past: prefix + "きた",      negativePast: prefix + "こなかった"),
                fullGroup(name: "Polite",     form: prefix + "きます",  negative: prefix + "きません",    past: prefix + "きました",   negativePast: prefix + "きませんでした"),
                fullGroup(name: "Progressive",form: prefix + "きている", negative: prefix + "きていない",  past: prefix + "きていた",   negativePast: prefix + "きていなかった"),
                fullGroup(name: "Desire",     form: prefix + "きたい",  negative: prefix + "きたくない",  past: prefix + "きたかった", negativePast: prefix + "きたくなかった"),
                volitionalGroup(volitional: prefix + "こよう", negative: prefix + "くるまい"),
                presumptiveGroup(plain: base, negative: prefix + "こない", past: prefix + "きた", negativePast: prefix + "こなかった"),
                fullGroup(name: "Potential",  form: prefix + "こられる", negative: prefix + "こられない",  past: prefix + "こられた",   negativePast: prefix + "こられなかった"),
                fullGroup(name: "Passive",    form: prefix + "こられる", negative: prefix + "こられない",  past: prefix + "こられた",   negativePast: prefix + "こられなかった"),
                fullGroup(name: "Causative",  form: prefix + "こさせる", negative: prefix + "こさせない",  past: prefix + "こさせた",   negativePast: prefix + "こさせなかった"),
                fullGroup(name: "Causative-passive", form: prefix + "こさせられる", negative: prefix + "こさせられない", past: prefix + "こさせられた", negativePast: prefix + "こさせられなかった"),
                conditionalGroup(ba: prefix + "くれば", negativeBa: prefix + "こなければ", past: prefix + "きた", negativePast: prefix + "こなかった"),
                ConjugationGroup(name: "Te-form", rows: [
                    ConjugationRow(label: "Te-form",   surface: prefix + "きて"),
                    ConjugationRow(label: "Tari-form", surface: prefix + "きたり"),
                ]),
                withoutDoingGroup(negative: prefix + "こない", negativeStem: prefix + "こ"),
                otherNegativesGroup(negativeStem: prefix + "こ"),
                ConjugationGroup(name: "Imperative", rows: [
                    ConjugationRow(label: "Imperative", surface: prefix + "こい"),
                    ConjugationRow(label: "Negative",   surface: base + "な"),
                ]),
                ConjugationGroup(name: "Noun form", rows: [
                    ConjugationRow(label: "Noun form", surface: prefix + "き"),
                ]),
            ]
        }

        // Kanji spelling: 来る (stem 来)
        if base.hasSuffix("来る") {
            let prefix = String(base.dropLast(2))
            return [
                fullGroup(name: "Plain",      form: base,               negative: prefix + "来ない",       past: prefix + "来た",      negativePast: prefix + "来なかった"),
                fullGroup(name: "Polite",     form: prefix + "来ます",   negative: prefix + "来ません",    past: prefix + "来ました",   negativePast: prefix + "来ませんでした"),
                fullGroup(name: "Progressive",form: prefix + "来ている",  negative: prefix + "来ていない",  past: prefix + "来ていた",   negativePast: prefix + "来ていなかった"),
                fullGroup(name: "Desire",     form: prefix + "来たい",   negative: prefix + "来たくない",  past: prefix + "来たかった", negativePast: prefix + "来たくなかった"),
                volitionalGroup(volitional: prefix + "来よう", negative: prefix + "来るまい"),
                presumptiveGroup(plain: base, negative: prefix + "来ない", past: prefix + "来た", negativePast: prefix + "来なかった"),
                fullGroup(name: "Potential",  form: prefix + "来られる",  negative: prefix + "来られない",  past: prefix + "来られた",   negativePast: prefix + "来られなかった"),
                fullGroup(name: "Passive",    form: prefix + "来られる",  negative: prefix + "来られない",  past: prefix + "来られた",   negativePast: prefix + "来られなかった"),
                fullGroup(name: "Causative",  form: prefix + "来させる",  negative: prefix + "来させない",  past: prefix + "来させた",   negativePast: prefix + "来させなかった"),
                fullGroup(name: "Causative-passive", form: prefix + "来させられる", negative: prefix + "来させられない", past: prefix + "来させられた", negativePast: prefix + "来させられなかった"),
                conditionalGroup(ba: prefix + "来れば", negativeBa: prefix + "来なければ", past: prefix + "来た", negativePast: prefix + "来なかった"),
                ConjugationGroup(name: "Te-form", rows: [
                    ConjugationRow(label: "Te-form",   surface: prefix + "来て"),
                    ConjugationRow(label: "Tari-form", surface: prefix + "来たり"),
                ]),
                withoutDoingGroup(negative: prefix + "来ない", negativeStem: prefix + "来"),
                otherNegativesGroup(negativeStem: prefix + "来"),
                ConjugationGroup(name: "Imperative", rows: [
                    ConjugationRow(label: "Imperative", surface: prefix + "来い"),
                    ConjugationRow(label: "Negative",   surface: base + "な"),
                ]),
                ConjugationGroup(name: "Noun form", rows: [
                    ConjugationRow(label: "Noun form", surface: prefix + "来"),
                ]),
            ]
        }

        // Fallback for unrecognized kuru spellings
        return ichidanGroups(base)
    }

    // MARK: Godan stem helpers

    // Maps a godan verb's final kana to the appropriate conjugation stem column.
    static func godanStem(lastKana: String, row: GodanRow) -> String? {
        let table: [String: (a: String, i: String, e: String, o: String)] = [
            "う": ("わ", "い", "え", "お"),
            "く": ("か", "き", "け", "こ"),
            "ぐ": ("が", "ぎ", "げ", "ご"),
            "す": ("さ", "し", "せ", "そ"),
            "つ": ("た", "ち", "て", "と"),
            "ぬ": ("な", "に", "ね", "の"),
            "ぶ": ("ば", "び", "べ", "ぼ"),
            "む": ("ま", "み", "め", "も"),
            "る": ("ら", "り", "れ", "ろ"),
        ]
        guard let entry = table[lastKana] else { return nil }
        switch row {
        case .a: return entry.a
        case .i: return entry.i
        case .e: return entry.e
        case .o: return entry.o
        }
    }

    // Computes the te-form and ta-form for a godan verb, including the 行く (v5k-s) and
    // 問う (v5u-s) irregularities.
    static func godanTeTa(base: String, lastKana: String, stem: String) -> (te: String, ta: String) {
        // 行く/いく/ゆく/逝く/往く (JMdict "v5k-s") are irregular: te-form is って not いて
        let ikuSuffixes = ["行く", "いく", "ゆく", "逝く", "往く"]
        if ikuSuffixes.contains(where: { base.hasSuffix($0) }) {
            return (stem + "って", stem + "った")
        }
        // 問う/請う/乞う/恋う (JMdict "v5u-s") keep the pre-onbin うて／うた instead of the
        // regular って／った sound change that other う-ending godan verbs take.
        let uSpecialSuffixes = ["問う", "請う", "乞う", "恋う"]
        if uSpecialSuffixes.contains(where: { base.hasSuffix($0) }) {
            return (stem + "うて", stem + "うた")
        }
        switch lastKana {
        case "う", "つ", "る": return (stem + "って", stem + "った")
        case "む", "ぶ", "ぬ": return (stem + "んで", stem + "んだ")
        case "く":             return (stem + "いて", stem + "いた")
        case "ぐ":             return (stem + "いで", stem + "いだ")
        case "す":             return (stem + "して", stem + "した")
        default:               return (stem + lastKana + "て", stem + lastKana + "た")
        }
    }
}
