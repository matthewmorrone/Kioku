import Foundation

// Powers the "Variants" / alternate-spellings section in WordDetailView.
// Extracted from WordDetailView so the kanji-and-kana filter logic can be unit
// tested without spinning up a SwiftUI view or the real dictionary.
//
// Rules (mirrors and extends the prior private implementation):
//
// 1. If the saved surface is pure kana, return []. A kana reading can map to
//    many different kanji spellings, so surfacing one entry's kanji forms
//    would imply a false uniqueness. (Same guard as before.)
//
// 2. Otherwise the saved surface contains kanji, and we collect both:
//      - kanji forms (other than the saved surface) with the SAME kanji
//        character count as the saved surface — alternate kanji spellings
//        (桜/櫻) swap kanji character-for-character, so the count matches. A
//        differing count (出すことは… vs 出す事は…, where 事 replaces こと)
//        means one internal word's script choice changed, not a distinct
//        spelling — a kanji↔kana swap in miniature, excluded like the below.
//      - kana forms, EXCLUDING the entry's primary (first) one — that's just
//        the headword's own reading written without kanji (already shown as
//        the reading beneath the headword), not a distinct "also written as"
//        spelling. Only further kana forms are kept, since those are real
//        orthographic variants (e.g. a づ/ず or ぢ/じ yotsugana pair both
//        listed on the entry) rather than a trivial kanji↔kana restatement.
//
// 3. Each form's JMdict info tags exclude archaic / search-only variants:
//      - kanji: ke_inf "oK" (out-dated) and "sK" (search-only) are dropped.
//      - kana:  re_inf "ok" (out-dated) and "sk" (search-only) are dropped.
//    Irregular forms (iK / ik) are kept — they're real writings worth knowing.
nonisolated enum WordVariants {
    // Returns the list of alternate kanji and kana spellings for one entry,
    // excluding the saved surface itself and any archaic / search-only forms.
    // Returns [] when the saved surface is pure kana — see file-level header
    // comment for the "false uniqueness" rationale.
    static func alternateSpellings(savedSurface: String, entry: DictionaryEntry) -> [String] {
        guard ScriptClassifier.containsKanji(savedSurface) else { return [] }

        // Same-count kanji forms only — a genuine alternate kanji spelling (桜/櫻) swaps individual
        // kanji character-for-character, so the kanji count matches. A kanjiForm whose kanji count
        // DIFFERS from the saved surface (出すことは… / 出す事は…, where 事 replaces こと) is really
        // the same phrase with one internal word's script choice changed — a kanji↔kana swap in
        // miniature, not a distinct spelling — so it's excluded the same way the primary reading is.
        let savedKanjiCount = kanjiCharacterCount(savedSurface)
        let kanjiAlternates = entry.kanjiForms
            .filter { form in
                let info = form.info ?? ""
                return form.text != savedSurface
                    && !info.contains("oK")
                    && !info.contains("sK")
                    && kanjiCharacterCount(form.text) == savedKanjiCount
            }
            .map(\.text)

        // Drops the entry's primary (first) kana form — that's just the headword's own reading
        // rendered without kanji, already shown as the reading beneath the headword elsewhere on
        // screen, not a genuinely distinct "also written as" spelling. Any FURTHER kana forms
        // (index 1+) are kept: those are real orthographic variants of the same word (e.g. a
        // づ/ず or ぢ/じ yotsugana pair both listed on the entry), which is what this section
        // should actually surface instead of restating the reading as if it were an alternative.
        let kanaAlternates = entry.kanaForms
            .dropFirst()
            .filter { form in
                let info = form.info ?? ""
                return form.text != savedSurface
                    && !info.contains("ok")
                    && !info.contains("sk")
            }
            .map(\.text)

        return kanjiAlternates + kanaAlternates
    }

    // Counts characters classified as kanji — used to detect a kanji↔kana script swap of one
    // internal word within a kanjiForm alternate (see alternateSpellings' kanjiAlternates filter).
    private static func kanjiCharacterCount(_ text: String) -> Int {
        text.reduce(0) { count, character in
            character.unicodeScalars.contains(where: ScriptClassifier.isKanjiScalar) ? count + 1 : count
        }
    }
}
