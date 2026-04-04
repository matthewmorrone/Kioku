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
    // Returns nil when no verb POS tag is found.
    static func detectVerbClass(fromJMDictPosTags tags: [String]) -> VerbClass? {
        let normalized = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if normalized.contains("vk") { return .kuru }
        if normalized.contains(where: { $0.hasPrefix("vs") }) { return .suru }
        if normalized.contains("v1") { return .ichidan }
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
        let groups = conjugationGroups(for: dictionaryForm, verbClass: verbClass)
        let teForm   = groups.first(where: { $0.name == "Te-form"  })?.rows.first
        let negative = groups.first(where: { $0.name == "Plain"    })?.rows.first(where: { $0.label == "Negative" })
        let past     = groups.first(where: { $0.name == "Plain"    })?.rows.first(where: { $0.label == "Past" })
        return [teForm, negative, past].compactMap { $0 }
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

    // MARK: Ichidan

    // Produces the full paradigm for ichidan (Group II / ru-verb) verbs.
    static func ichidanGroups(_ base: String) -> [ConjugationGroup] {
        guard base.hasSuffix("る"), base.count >= 2 else { return [] }
        let stem = String(base.dropLast())

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
            fullGroup(
                name: "Volitional",
                form: stem + "よう",
                negative: base + "まい",
                past: stem + "たろう",
                negativePast: stem + "なかったろう"
            ),
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
            ConjugationGroup(name: "Conditional", rows: [
                ConjugationRow(label: "Conditional",   surface: stem + "れば"),
                ConjugationRow(label: "Negative",      surface: stem + "なければ"),
                ConjugationRow(label: "Past",          surface: stem + "たら"),
                ConjugationRow(label: "Negative past", surface: stem + "なかったら"),
            ]),
            ConjugationGroup(name: "Te-form", rows: [
                ConjugationRow(label: "Te-form",   surface: stem + "て"),
                ConjugationRow(label: "Tari-form", surface: stem + "たり"),
            ]),
            ConjugationGroup(name: "Without doing", rows: [
                ConjugationRow(label: "Without doing", surface: stem + "ないで"),
                ConjugationRow(label: "Formal",        surface: stem + "ずに"),
                ConjugationRow(label: "Classical",     surface: stem + "ぬ／ん"),
            ]),
            ConjugationGroup(name: "Imperative", rows: [
                ConjugationRow(label: "Imperative", surface: stem + "ろ"),
                ConjugationRow(label: "Negative",   surface: base + "な"),
            ]),
            ConjugationGroup(name: "Noun form", rows: [
                ConjugationRow(label: "Noun form", surface: stem),
            ]),
        ]
    }

    // MARK: Godan

    // Produces the full paradigm for godan (Group I / u-verb) verbs.
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

        return [
            fullGroup(
                name: "Plain",
                form: base,
                negative: stem + aStem + "ない",
                past: ta,
                negativePast: stem + aStem + "なかった"
            ),
            fullGroup(
                name: "Polite",
                form: stem + iStem + "ます",
                negative: stem + iStem + "ません",
                past: stem + iStem + "ました",
                negativePast: stem + iStem + "ませんでした"
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
                form: stem + iStem + "たい",
                negative: stem + iStem + "たくない",
                past: stem + iStem + "たかった",
                negativePast: stem + iStem + "たくなかった"
            ),
            fullGroup(
                name: "Volitional",
                form: stem + oStem + "う",
                negative: base + "まい",
                past: ta + "ろう",
                negativePast: stem + aStem + "なかったろう"
            ),
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
            ConjugationGroup(name: "Conditional", rows: [
                ConjugationRow(label: "Conditional",   surface: stem + eStem + "ば"),
                ConjugationRow(label: "Negative",      surface: stem + aStem + "なければ"),
                ConjugationRow(label: "Past",          surface: ta + "ら"),
                ConjugationRow(label: "Negative past", surface: stem + aStem + "なかったら"),
            ]),
            ConjugationGroup(name: "Te-form", rows: [
                ConjugationRow(label: "Te-form",   surface: te),
                ConjugationRow(label: "Tari-form", surface: ta + "り"),
            ]),
            ConjugationGroup(name: "Without doing", rows: [
                ConjugationRow(label: "Without doing", surface: stem + aStem + "ないで"),
                ConjugationRow(label: "Formal",        surface: stem + aStem + "ずに"),
                ConjugationRow(label: "Classical",     surface: stem + aStem + "ぬ／ん"),
            ]),
            ConjugationGroup(name: "Imperative", rows: [
                ConjugationRow(label: "Imperative", surface: stem + eStem),
                ConjugationRow(label: "Negative",   surface: base + "な"),
            ]),
            ConjugationGroup(name: "Noun form", rows: [
                ConjugationRow(label: "Noun form", surface: stem + iStem),
            ]),
        ]
    }

    // MARK: Suru

    // Produces the full paradigm for suru-compound verbs (e.g. 勉強する).
    static func suruGroups(_ base: String) -> [ConjugationGroup] {
        guard base.hasSuffix("する"), base.count >= 3 else { return [] }
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
            fullGroup(
                name: "Volitional",
                form: prefix + "しよう",
                negative: prefix + "するまい",
                past: prefix + "したろう",
                negativePast: prefix + "しなかったろう"
            ),
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
            ConjugationGroup(name: "Conditional", rows: [
                ConjugationRow(label: "Conditional",   surface: prefix + "すれば"),
                ConjugationRow(label: "Negative",      surface: prefix + "しなければ"),
                ConjugationRow(label: "Past",          surface: prefix + "したら"),
                ConjugationRow(label: "Negative past", surface: prefix + "しなかったら"),
            ]),
            ConjugationGroup(name: "Te-form", rows: [
                ConjugationRow(label: "Te-form",   surface: prefix + "して"),
                ConjugationRow(label: "Tari-form", surface: prefix + "したり"),
            ]),
            ConjugationGroup(name: "Without doing", rows: [
                ConjugationRow(label: "Without doing", surface: prefix + "しないで"),
                ConjugationRow(label: "Formal",        surface: prefix + "せずに"),
                ConjugationRow(label: "Classical",     surface: prefix + "せぬ／ん"),
            ]),
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
                fullGroup(name: "Volitional", form: prefix + "こよう",  negative: prefix + "くるまい",    past: prefix + "きたろう",   negativePast: prefix + "こなかったろう"),
                fullGroup(name: "Potential",  form: prefix + "こられる", negative: prefix + "こられない",  past: prefix + "こられた",   negativePast: prefix + "こられなかった"),
                fullGroup(name: "Passive",    form: prefix + "こられる", negative: prefix + "こられない",  past: prefix + "こられた",   negativePast: prefix + "こられなかった"),
                fullGroup(name: "Causative",  form: prefix + "こさせる", negative: prefix + "こさせない",  past: prefix + "こさせた",   negativePast: prefix + "こさせなかった"),
                fullGroup(name: "Causative-passive", form: prefix + "こさせられる", negative: prefix + "こさせられない", past: prefix + "こさせられた", negativePast: prefix + "こさせられなかった"),
                ConjugationGroup(name: "Conditional", rows: [
                    ConjugationRow(label: "Conditional",   surface: prefix + "くれば"),
                    ConjugationRow(label: "Negative",      surface: prefix + "こなければ"),
                    ConjugationRow(label: "Past",          surface: prefix + "きたら"),
                    ConjugationRow(label: "Negative past", surface: prefix + "こなかったら"),
                ]),
                ConjugationGroup(name: "Te-form", rows: [
                    ConjugationRow(label: "Te-form",   surface: prefix + "きて"),
                    ConjugationRow(label: "Tari-form", surface: prefix + "きたり"),
                ]),
                ConjugationGroup(name: "Without doing", rows: [
                    ConjugationRow(label: "Without doing", surface: prefix + "こないで"),
                    ConjugationRow(label: "Formal",        surface: prefix + "こずに"),
                    ConjugationRow(label: "Classical",     surface: prefix + "こぬ／ん"),
                ]),
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
                fullGroup(name: "Volitional", form: prefix + "来よう",   negative: prefix + "来るまい",    past: prefix + "来たろう",   negativePast: prefix + "来なかったろう"),
                fullGroup(name: "Potential",  form: prefix + "来られる",  negative: prefix + "来られない",  past: prefix + "来られた",   negativePast: prefix + "来られなかった"),
                fullGroup(name: "Passive",    form: prefix + "来られる",  negative: prefix + "来られない",  past: prefix + "来られた",   negativePast: prefix + "来られなかった"),
                fullGroup(name: "Causative",  form: prefix + "来させる",  negative: prefix + "来させない",  past: prefix + "来させた",   negativePast: prefix + "来させなかった"),
                fullGroup(name: "Causative-passive", form: prefix + "来させられる", negative: prefix + "来させられない", past: prefix + "来させられた", negativePast: prefix + "来させられなかった"),
                ConjugationGroup(name: "Conditional", rows: [
                    ConjugationRow(label: "Conditional",   surface: prefix + "来れば"),
                    ConjugationRow(label: "Negative",      surface: prefix + "来なければ"),
                    ConjugationRow(label: "Past",          surface: prefix + "来たら"),
                    ConjugationRow(label: "Negative past", surface: prefix + "来なかったら"),
                ]),
                ConjugationGroup(name: "Te-form", rows: [
                    ConjugationRow(label: "Te-form",   surface: prefix + "来て"),
                    ConjugationRow(label: "Tari-form", surface: prefix + "来たり"),
                ]),
                ConjugationGroup(name: "Without doing", rows: [
                    ConjugationRow(label: "Without doing", surface: prefix + "来ないで"),
                    ConjugationRow(label: "Formal",        surface: prefix + "来ずに"),
                    ConjugationRow(label: "Classical",     surface: prefix + "来ぬ／ん"),
                ]),
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

    // Computes the te-form and ta-form for a godan verb, including the 行く irregularity.
    static func godanTeTa(base: String, lastKana: String, stem: String) -> (te: String, ta: String) {
        // 行く is irregular: te-form is って not いて
        if base.hasSuffix("行く") || base.hasSuffix("いく") {
            return (stem + "って", stem + "った")
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
