# Word Detail Full Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the full WordDetailView as designed in the mockup, including an expanded VerbConjugator, ConjugationGroup model, ConjugationSheetView, and WordDetailView changes for compound definition layout, Forms section, and sense number suppression.

**Architecture:** `VerbConjugator` (ported and expanded from archive) produces `[ConjugationGroup]` — each group is a named paradigm (Plain, Polite, Progressive, etc.) with rows of `(label, surface)`. `ConjugationSheetView` renders these groups as cards in a bottom sheet. `WordDetailView` gains a Forms section that shows 3 key forms inline and opens the sheet, and its Definition section is refactored to show compound components as separate cards.

**Tech Stack:** Swift 6, SwiftUI, JMdict POS tags (v1, v5*, vk, vs*, adj-i), existing `DictionaryStore`, `WordDisplayData`, `JMdictTagExpander`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `Kioku/Dictionary/Conjugation/ConjugationGroup.swift` | Create | `ConjugationRow` and `ConjugationGroup` value types |
| `Kioku/Dictionary/Conjugation/VerbConjugator.swift` | Create | Full conjugation engine for all verb classes and adjectives |
| `Kioku/Words/ConjugationSheetView.swift` | Create | Bottom sheet showing all conjugation groups as cards |
| `Kioku/Words/WordDetailView.swift` | Modify | Forms section, compound definition cards, sense number suppression |

---

## Task 1: ConjugationGroup model

**Files:**
- Create: `Kioku/Dictionary/Conjugation/ConjugationGroup.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation

// One row in a conjugation paradigm card — the Japanese surface form and its English label.
struct ConjugationRow: Hashable, Sendable {
    // The English label for this row: the paradigm name (e.g. "Plain") for the first row,
    // or "Negative", "Past", "Negative past" for the remaining rows.
    let label: String
    // The conjugated Japanese surface form.
    let surface: String
}

// One paradigm card shown in ConjugationSheetView — e.g. "Plain" with rows for
// plain / negative / past / negative past forms.
struct ConjugationGroup: Identifiable, Sendable {
    // The paradigm name shown as the card title — e.g. "Plain", "Polite", "Progressive".
    let name: String
    // Ordered rows for this paradigm. First row label matches `name`.
    let rows: [ConjugationRow]

    var id: String { name }
}
```

- [ ] **Step 2: Commit**

```bash
git add Kioku/Dictionary/Conjugation/ConjugationGroup.swift
git commit -m "feat: add ConjugationGroup model for conjugation sheet"
```

---

## Task 2: VerbConjugator — ichidan, godan, suru, kuru

**Files:**
- Create: `Kioku/Dictionary/Conjugation/VerbConjugator.swift`

This file replaces and expands the archived `archive/kyouku/kyouku/VerbConjugator.swift`. The new version produces `[ConjugationGroup]` instead of `[VerbConjugation]`, and covers the full paradigm.

**Paradigm groups and their row labels:**

Every group that has a full tense paradigm uses these 4 row labels in order:
1. The group name itself (e.g. "Plain") — the dictionary/base form
2. "Negative"
3. "Past"
4. "Negative past"

Groups with a partial paradigm (te-form, tari, naide/sezu/nu, imperative, noun form) use only what applies.

- [ ] **Step 1: Write failing test**

Create `KiokuTests/Dictionary/VerbConjugatorTests.swift`:

```swift
import XCTest
@testable import Kioku

final class VerbConjugatorTests: XCTestCase {

    // MARK: Ichidan

    func test_ichidan_plain() {
        let groups = VerbConjugator.conjugationGroups(for: "食べる", verbClass: .ichidan)
        let plain = groups.first(where: { $0.name == "Plain" })!
        XCTAssertEqual(plain.rows[0].surface, "食べる")
        XCTAssertEqual(plain.rows[1].surface, "食べない")
        XCTAssertEqual(plain.rows[2].surface, "食べた")
        XCTAssertEqual(plain.rows[3].surface, "食べなかった")
    }

    func test_ichidan_polite() {
        let groups = VerbConjugator.conjugationGroups(for: "食べる", verbClass: .ichidan)
        let polite = groups.first(where: { $0.name == "Polite" })!
        XCTAssertEqual(polite.rows[0].surface, "食べます")
        XCTAssertEqual(polite.rows[1].surface, "食べません")
        XCTAssertEqual(polite.rows[2].surface, "食べました")
        XCTAssertEqual(polite.rows[3].surface, "食べませんでした")
    }

    func test_ichidan_teForm() {
        let groups = VerbConjugator.conjugationGroups(for: "食べる", verbClass: .ichidan)
        let te = groups.first(where: { $0.name == "Te-form" })!
        XCTAssertEqual(te.rows[0].surface, "食べて")
        XCTAssertEqual(te.rows[1].surface, "食べたり")
    }

    func test_ichidan_naideSezu() {
        let groups = VerbConjugator.conjugationGroups(for: "食べる", verbClass: .ichidan)
        let g = groups.first(where: { $0.name == "Without doing" })!
        XCTAssertEqual(g.rows[0].surface, "食べないで")
        XCTAssertEqual(g.rows[1].surface, "食べずに")
        XCTAssertEqual(g.rows[2].surface, "食べぬ／ん")
    }

    func test_ichidan_nounForm() {
        let groups = VerbConjugator.conjugationGroups(for: "食べる", verbClass: .ichidan)
        let g = groups.first(where: { $0.name == "Noun form" })!
        XCTAssertEqual(g.rows[0].surface, "食べ")
    }

    // MARK: Godan

    func test_godan_su_plain() {
        let groups = VerbConjugator.conjugationGroups(for: "探す", verbClass: .godan)
        let plain = groups.first(where: { $0.name == "Plain" })!
        XCTAssertEqual(plain.rows[0].surface, "探す")
        XCTAssertEqual(plain.rows[1].surface, "探さない")
        XCTAssertEqual(plain.rows[2].surface, "探した")
        XCTAssertEqual(plain.rows[3].surface, "探さなかった")
    }

    func test_godan_ku_teForm() {
        let groups = VerbConjugator.conjugationGroups(for: "書く", verbClass: .godan)
        let te = groups.first(where: { $0.name == "Te-form" })!
        XCTAssertEqual(te.rows[0].surface, "書いて")
    }

    func test_godan_iku_teForm() {
        // 行く is irregular — て-form is いって not いいて
        let groups = VerbConjugator.conjugationGroups(for: "行く", verbClass: .godan)
        let te = groups.first(where: { $0.name == "Te-form" })!
        XCTAssertEqual(te.rows[0].surface, "行って")
    }

    func test_godan_naideSezu() {
        let groups = VerbConjugator.conjugationGroups(for: "探す", verbClass: .godan)
        let g = groups.first(where: { $0.name == "Without doing" })!
        XCTAssertEqual(g.rows[0].surface, "探さないで")
        XCTAssertEqual(g.rows[1].surface, "探さずに")
        XCTAssertEqual(g.rows[2].surface, "探さぬ／ん")
    }

    // MARK: Suru

    func test_suru_plain() {
        let groups = VerbConjugator.conjugationGroups(for: "勉強する", verbClass: .suru)
        let plain = groups.first(where: { $0.name == "Plain" })!
        XCTAssertEqual(plain.rows[0].surface, "勉強する")
        XCTAssertEqual(plain.rows[1].surface, "勉強しない")
        XCTAssertEqual(plain.rows[2].surface, "勉強した")
        XCTAssertEqual(plain.rows[3].surface, "勉強しなかった")
    }

    func test_suru_naideSezu() {
        let groups = VerbConjugator.conjugationGroups(for: "勉強する", verbClass: .suru)
        let g = groups.first(where: { $0.name == "Without doing" })!
        XCTAssertEqual(g.rows[0].surface, "勉強しないで")
        XCTAssertEqual(g.rows[1].surface, "勉強せずに")
        XCTAssertEqual(g.rows[2].surface, "勉強せぬ／ん")
    }

    // MARK: Kuru

    func test_kuru_plain() {
        let groups = VerbConjugator.conjugationGroups(for: "来る", verbClass: .kuru)
        let plain = groups.first(where: { $0.name == "Plain" })!
        XCTAssertEqual(plain.rows[0].surface, "来る")
        XCTAssertEqual(plain.rows[1].surface, "来ない")
        XCTAssertEqual(plain.rows[2].surface, "来た")
        XCTAssertEqual(plain.rows[3].surface, "来なかった")
    }

    // MARK: Detect verb class

    func test_detectVerbClass_ichidan() {
        XCTAssertEqual(VerbConjugator.detectVerbClass(fromJMDictPosTags: ["v1"]), .ichidan)
    }

    func test_detectVerbClass_godan() {
        XCTAssertEqual(VerbConjugator.detectVerbClass(fromJMDictPosTags: ["v5s"]), .godan)
    }

    func test_detectVerbClass_suru() {
        XCTAssertEqual(VerbConjugator.detectVerbClass(fromJMDictPosTags: ["vs-i"]), .suru)
    }

    func test_detectVerbClass_kuru() {
        XCTAssertEqual(VerbConjugator.detectVerbClass(fromJMDictPosTags: ["vk"]), .kuru)
    }

    // MARK: Key forms

    func test_keyForms_ichidan() {
        let forms = VerbConjugator.keyForms(for: "食べる", verbClass: .ichidan)
        XCTAssertEqual(forms.count, 3)
        XCTAssertEqual(forms[0].label, "Te-form")
        XCTAssertEqual(forms[0].surface, "食べて")
        XCTAssertEqual(forms[1].label, "Negative")
        XCTAssertEqual(forms[1].surface, "食べない")
        XCTAssertEqual(forms[2].label, "Past")
        XCTAssertEqual(forms[2].surface, "食べた")
    }
}
```

- [ ] **Step 2: Run test to confirm it fails**

```
xcodebuild test -scheme Kioku -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing KiokuTests/VerbConjugatorTests 2>&1 | tail -20
```

Expected: compile error — `VerbConjugator` not found.

- [ ] **Step 3: Implement VerbConjugator**

Create `Kioku/Dictionary/Conjugation/VerbConjugator.swift`:

```swift
import Foundation

// Generates conjugation paradigm groups for Japanese verbs and i-adjectives.
// Each group corresponds to one card in ConjugationSheetView.
// Port and expansion of archive/kyouku/kyouku/VerbConjugator.swift.
struct VerbConjugator {

    enum VerbClass: Hashable, Sendable {
        case ichidan
        case godan
        case suru
        case kuru
    }

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
        let teForm  = groups.first(where: { $0.name == "Te-form"  })?.rows.first
        let negative = groups.first(where: { $0.name == "Plain"   })?.rows.first(where: { $0.label == "Negative" })
        let past     = groups.first(where: { $0.name == "Plain"   })?.rows.first(where: { $0.label == "Past" })
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
                negative: stem + "まい",
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
                ConjugationRow(label: "Conditional",      surface: stem + "れば"),
                ConjugationRow(label: "Negative",         surface: stem + "なければ"),
                ConjugationRow(label: "Past",             surface: stem + "たら"),
                ConjugationRow(label: "Negative past",    surface: stem + "なかったら"),
            ]),
            ConjugationGroup(name: "Te-form", rows: [
                ConjugationRow(label: "Te-form",  surface: stem + "て"),
                ConjugationRow(label: "Tari-form", surface: stem + "たり"),
            ]),
            ConjugationGroup(name: "Without doing", rows: [
                ConjugationRow(label: "Without doing",          surface: stem + "ないで"),
                ConjugationRow(label: "Formal",                 surface: stem + "ずに"),
                ConjugationRow(label: "Classical",              surface: stem + "ぬ／ん"),
            ]),
            ConjugationGroup(name: "Imperative", rows: [
                ConjugationRow(label: "Imperative",          surface: stem + "ろ"),
                ConjugationRow(label: "Negative",            surface: base + "な"),
            ]),
            ConjugationGroup(name: "Noun form", rows: [
                ConjugationRow(label: "Noun form", surface: stem),
            ]),
        ]
    }

    // MARK: Godan

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
                ConjugationRow(label: "Imperative",      surface: prefix + "しろ"),
                ConjugationRow(label: "Imperative (alt)", surface: prefix + "せよ"),
                ConjugationRow(label: "Negative",        surface: base + "な"),
            ]),
            ConjugationGroup(name: "Noun form", rows: [
                ConjugationRow(label: "Noun form", surface: prefix + "し"),
            ]),
        ]
    }

    // MARK: Kuru

    static func kuruGroups(_ base: String) -> [ConjugationGroup] {
        // Kana spelling: くる
        if base.hasSuffix("くる") {
            let prefix = String(base.dropLast(2))
            return [
                fullGroup(name: "Plain",      form: base,           negative: prefix + "こない",      past: prefix + "きた",    negativePast: prefix + "こなかった"),
                fullGroup(name: "Polite",     form: prefix + "きます", negative: prefix + "きません",   past: prefix + "きました", negativePast: prefix + "きませんでした"),
                fullGroup(name: "Progressive",form: prefix + "きている",negative: prefix + "きていない", past: prefix + "きていた",negativePast: prefix + "きていなかった"),
                fullGroup(name: "Desire",     form: prefix + "きたい", negative: prefix + "きたくない",  past: prefix + "きたかった",negativePast: prefix + "きたくなかった"),
                fullGroup(name: "Volitional", form: prefix + "こよう", negative: prefix + "くるまい",   past: prefix + "きたろう", negativePast: prefix + "こなかったろう"),
                fullGroup(name: "Potential",  form: prefix + "こられる",negative: prefix + "こられない", past: prefix + "こられた", negativePast: prefix + "こられなかった"),
                fullGroup(name: "Passive",    form: prefix + "こられる",negative: prefix + "こられない", past: prefix + "こられた", negativePast: prefix + "こられなかった"),
                fullGroup(name: "Causative",  form: prefix + "こさせる",negative: prefix + "こさせない", past: prefix + "こさせた", negativePast: prefix + "こさせなかった"),
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
                fullGroup(name: "Plain",      form: base,             negative: prefix + "来ない",       past: prefix + "来た",     negativePast: prefix + "来なかった"),
                fullGroup(name: "Polite",     form: prefix + "来ます",  negative: prefix + "来ません",    past: prefix + "来ました",  negativePast: prefix + "来ませんでした"),
                fullGroup(name: "Progressive",form: prefix + "来ている", negative: prefix + "来ていない",  past: prefix + "来ていた",  negativePast: prefix + "来ていなかった"),
                fullGroup(name: "Desire",     form: prefix + "来たい",  negative: prefix + "来たくない",   past: prefix + "来たかった",negativePast: prefix + "来たくなかった"),
                fullGroup(name: "Volitional", form: prefix + "来よう",  negative: prefix + "来るまい",    past: prefix + "来たろう",  negativePast: prefix + "来なかったろう"),
                fullGroup(name: "Potential",  form: prefix + "来られる", negative: prefix + "来られない",  past: prefix + "来られた",  negativePast: prefix + "来られなかった"),
                fullGroup(name: "Passive",    form: prefix + "来られる", negative: prefix + "来られない",  past: prefix + "来られた",  negativePast: prefix + "来られなかった"),
                fullGroup(name: "Causative",  form: prefix + "来させる", negative: prefix + "来させない",  past: prefix + "来させた",  negativePast: prefix + "来させなかった"),
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

        // Fallback
        return ichidanGroups(base)
    }

    // MARK: Godan stem helpers

    enum GodanRow { case a, i, e, o }

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
```

- [ ] **Step 4: Run tests**

```
xcodebuild test -scheme Kioku -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing KiokuTests/VerbConjugatorTests 2>&1 | tail -30
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Kioku/Dictionary/Conjugation/VerbConjugator.swift KiokuTests/Dictionary/VerbConjugatorTests.swift
git commit -m "feat: add VerbConjugator with full paradigm groups"
```

---

## Task 3: ConjugationSheetView

**Files:**
- Create: `Kioku/Words/ConjugationSheetView.swift`

- [ ] **Step 1: Create the view**

```swift
import SwiftUI

// Bottom sheet showing all conjugation groups for a word.
// Renders each ConjugationGroup as a rounded card with Japanese on the left
// and the English row label (secondary, small) on the right.
// Each row is tappable — tapping opens the lookup sheet for that surface form.
// Screen: ConjugationSheetView, presented from WordDetailView.
// Layout sections: drag handle, title bar, scrollable card list.
struct ConjugationSheetView: View {
    // The dictionary form shown in the title bar.
    let dictionaryForm: String
    // All conjugation groups to display.
    let groups: [ConjugationGroup]
    // Called when a conjugated surface is tapped — opens lookup for that form.
    let onLookup: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                            Button {
                                onLookup(row.surface)
                            } label: {
                                HStack {
                                    Text(row.surface)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(row.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text(group.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(dictionaryForm)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

```
xcodebuild build -scheme Kioku -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "error:|warning:|BUILD"
```

Expected: `BUILD SUCCEEDED` with no errors.

- [ ] **Step 3: Commit**

```bash
git add Kioku/Words/ConjugationSheetView.swift
git commit -m "feat: add ConjugationSheetView for full conjugation table"
```

---

## Task 4: WordDetailView — Forms section and compound definition cards

**Files:**
- Modify: `Kioku/Words/WordDetailView.swift`

This task makes four changes:
1. Add `@State private var showingConjugations = false` and `@State private var conjugationGroups: [ConjugationGroup] = []`
2. Add `isVerb` computed property from POS tags
3. Add a **Forms** section after Definition, before Also Written As
4. Refactor the Definition section: when `wordComponents` is non-empty, render each component as its own card (`listRowBackground` + `listRowInsets`). When there is only one sense, omit the sense number.
5. Wire `showingConjugations` sheet to `ConjugationSheetView`

- [ ] **Step 1: Add state and computed property**

In `WordDetailView`, after the existing `@State private var senseReferences` line, add:

```swift
@State private var showingConjugations: Bool = false
@State private var conjugationGroups: [ConjugationGroup] = []
```

After `isCommonWord`, add:

```swift
// Returns the verb class detected from the saved entry's POS tags, or nil for non-verbs.
// Used to decide whether to show the Forms section.
private var verbClass: VerbConjugator.VerbClass? {
    guard let entry = savedDisplayData?.entry else { return nil }
    let posTags = entry.senses.compactMap(\.pos).flatMap { $0.components(separatedBy: ",") }
    return VerbConjugator.detectVerbClass(fromJMDictPosTags: posTags)
}
```

- [ ] **Step 2: Add conjugation group computation to loadDisplayData**

At the end of `loadDisplayData()`, after the `senseReferences` fetch, add:

```swift
// Compute conjugation groups if this is a verb — uses the saved entry's primary kanji or kana form.
if let vc = verbClass,
   let form = savedDisplayData?.entry.kanjiForms.first?.text
           ?? savedDisplayData?.entry.kanaForms.first?.text {
    conjugationGroups = VerbConjugator.conjugationGroups(for: form, verbClass: vc)
}
```

- [ ] **Step 3: Refactor senseRow to suppress number when count == 1**

Replace the `senseRow` signature and the number label:

```swift
// Renders one sense with POS label, gloss, metadata tags, and optional cross-references.
// showNumber: pass false when the entry has only one sense — the number adds no information.
// freqLabel is non-nil only for the first sense of an entry.
@ViewBuilder
private func senseRow(number: Int, sense: DictionaryEntrySense, refs: [SenseReference] = [], freqLabel: String? = nil, showNumber: Bool = true) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if showNumber {
                Text("\(number).")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let pos = sense.pos, pos.isEmpty == false {
                        Text(JMdictTagExpander.expandAll(pos))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    if let label = freqLabel {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(sense.glosses.joined(separator: "; "))
                    .font(.subheadline)
            }
        }

        let tags = [sense.misc, sense.field, sense.dialect]
            .compactMap { $0 }
            .filter { $0.isEmpty == false }
            .map { JMdictTagExpander.expandAll($0) }
        if tags.isEmpty == false {
            HStack(spacing: 4) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.leading, showNumber ? 24 : 0)
        }

        let xrefs = refs.filter { $0.type == .xref }.map(\.target)
        let ants  = refs.filter { $0.type == .ant  }.map(\.target)
        if xrefs.isEmpty == false {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("See also:")
                    .font(.caption2).foregroundStyle(.tertiary)
                Text(xrefs.joined(separator: "、"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.leading, showNumber ? 24 : 0)
        }
        if ants.isEmpty == false {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Antonym:")
                    .font(.caption2).foregroundStyle(.tertiary)
                Text(ants.joined(separator: "、"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.leading, showNumber ? 24 : 0)
        }
    }
    .padding(.vertical, 2)
}
```

Update all call sites in the Definition ForEach to pass `showNumber: data.entry.senses.count > 1`:

```swift
senseRow(
    number: idx + 1,
    sense: sense,
    refs: senseRefs,
    freqLabel: idx == 0 ? freqLabel : nil,
    showNumber: data.entry.senses.count > 1
)
```

- [ ] **Step 4: Add Forms section**

After the Definition section's closing `}` and before the Also Written As section, add:

```swift
// Forms section — shown for verbs only. Displays te-form / negative / past inline,
// with an "All conjugations" row that opens ConjugationSheetView.
if let vc = verbClass,
   let dictionaryForm = savedDisplayData?.entry.kanjiForms.first?.text
                     ?? savedDisplayData?.entry.kanaForms.first?.text {
    let keyForms = VerbConjugator.keyForms(for: dictionaryForm, verbClass: vc)
    if keyForms.isEmpty == false {
        Section("Forms") {
            ForEach(keyForms, id: \.surface) { form in
                HStack {
                    Text(form.surface)
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Text(form.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                showingConjugations = true
            } label: {
                HStack {
                    Text("All conjugations")
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
```

- [ ] **Step 5: Wire the sheet**

Add `.sheet` modifier on the `List`:

```swift
.sheet(isPresented: $showingConjugations) {
    if let vc = verbClass,
       let dictionaryForm = savedDisplayData?.entry.kanjiForms.first?.text
                         ?? savedDisplayData?.entry.kanaForms.first?.text {
        ConjugationSheetView(
            dictionaryForm: dictionaryForm,
            groups: conjugationGroups,
            onLookup: { _ in
                // Tapping a conjugated form — lookup integration is a future task.
                // For now, dismiss the sheet.
                showingConjugations = false
            }
        )
        .presentationDetents([.large])
    }
}
```

- [ ] **Step 6: Build to confirm it compiles**

```
xcodebuild build -scheme Kioku -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "error:|BUILD"
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add Kioku/Words/WordDetailView.swift
git commit -m "feat: add Forms section and refactor sense number suppression in WordDetailView"
```

---

## Task 5: Compound definition cards in WordDetailView

**Files:**
- Modify: `Kioku/Words/WordDetailView.swift`

When `wordComponents` is non-empty, the Definition section should render each component as its own card. The component surface is shown as a small header label above its senses. Grammaticalized auxiliaries (続ける, させる, てもらう, てあげる, etc.) get an "auxiliary" badge.

- [ ] **Step 1: Add auxiliary detection helper**

Add this private function to `WordDetailView`:

```swift
// Returns true when a component surface is a grammaticalized auxiliary verb in this compound context.
// These are ichidan verbs that function as aspect/voice markers when suffixed to a masu-stem.
// Checked by exact match against known auxiliary surfaces.
private func isAuxiliaryComponent(_ surface: String) -> Bool {
    let auxiliaries: Set<String> = [
        "続ける", "始める", "終わる", "出す", "込む", "合う", "切る",
        "もらう", "あげる", "くれる", "いく", "くる", "おく", "みる",
        "しまう", "ある", "いる", "させる", "もらえる",
    ]
    return auxiliaries.contains(surface)
}
```

- [ ] **Step 2: Refactor the Definition section**

Replace the existing Definition section in `body`:

```swift
if sortedData.isEmpty == false {
    Section("Definition") {
        if wordComponents.isEmpty == false {
            // Compound word: one card per component showing that component's definition.
            ForEach(wordComponents, id: \.surface) { component in
                VStack(alignment: .leading, spacing: 0) {
                    // Component label row with optional auxiliary badge.
                    HStack(spacing: 6) {
                        Text(component.surface)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if isAuxiliaryComponent(component.surface) {
                            Text("auxiliary")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.purple)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    .padding(.bottom, 4)

                    if let gloss = component.gloss {
                        Text(gloss)
                            .font(.subheadline)
                    }
                }
                .padding(.vertical, 6)
            }
        } else {
            // Single entry: standard sense rows.
            ForEach(sortedData, id: \.entry.entryId) { data in
                if data.entry.senses.isEmpty == false {
                    definitionSectionHeader(for: data.entry)
                    let freqLabel = FrequencyData(jpdbRank: data.entry.jpdbRank, wordfreqZipf: data.entry.wordfreqZipf).frequencyLabel
                    ForEach(Array(data.entry.senses.enumerated()), id: \.offset) { idx, sense in
                        let senseRefs = data.entry.entryId == word.canonicalEntryID
                            ? senseReferences.filter { $0.senseOrderIndex == idx }
                            : []
                        senseRow(
                            number: idx + 1,
                            sense: sense,
                            refs: senseRefs,
                            freqLabel: idx == 0 ? freqLabel : nil,
                            showNumber: data.entry.senses.count > 1
                        )
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 3: Build**

```
xcodebuild build -scheme Kioku -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "error:|BUILD"
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Kioku/Words/WordDetailView.swift
git commit -m "feat: render compound word components as definition cards with auxiliary badge"
```

---

## Self-Review

**Spec coverage:**
- ✅ ConjugationGroup model — Task 1
- ✅ VerbConjugator full paradigm (plain, polite, progressive, desire, volitional, potential, passive, causative, causative-passive, conditional, te-form, tari, naide/sezu/nu, imperative, noun form) — Task 2
- ✅ ConjugationSheetView — Task 3
- ✅ Forms section in WordDetailView with key forms + "All conjugations" button — Task 4
- ✅ Sense number suppression when only one sense — Task 4
- ✅ Compound definition cards — Task 5
- ✅ Auxiliary badge for grammaticalized helpers — Task 5
- ✅ Frequency label inline (already implemented, no task needed)

**Placeholder scan:** None found.

**Type consistency:**
- `ConjugationRow` defined in Task 1, used in Tasks 2, 3, 4 — consistent
- `ConjugationGroup.name` used as card title and in `keyForms` lookup by name — consistent
- `VerbConjugator.detectVerbClass` and `conjugationGroups` called in Task 4 — match Task 2 signatures
- `showNumber` parameter added to `senseRow` in Task 4 — used in both the refactored Definition section (Task 5) and the original sense path
