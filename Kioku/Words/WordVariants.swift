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
//      - kanji forms (other than the saved surface) — new, this is what the
//        todo asked for.
//      - kana forms — preserved from the prior behavior.
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

        let kanjiAlternates = entry.kanjiForms
            .filter { form in
                let info = form.info ?? ""
                return form.text != savedSurface
                    && !info.contains("oK")
                    && !info.contains("sK")
            }
            .map(\.text)

        let kanaAlternates = entry.kanaForms
            .filter { form in
                let info = form.info ?? ""
                return form.text != savedSurface
                    && !info.contains("ok")
                    && !info.contains("sk")
            }
            .map(\.text)

        return kanjiAlternates + kanaAlternates
    }
}
