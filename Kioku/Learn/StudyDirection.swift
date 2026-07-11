import Foundation

// Shared "which way am I being quizzed" axis for the Learn-tab study modes (Flashcards and
// Multiple Choice present the identical control). Orthogonal to `StudyJapaneseForm`: this picks
// which side is the prompt; that picks how the Japanese side is written.
enum StudyDirection: String, CaseIterable, Identifiable {
    // Prompt is Japanese, answer is the English meaning (recognition).
    case japaneseToEnglish = "日本語 → English"
    // Prompt is the English meaning, answer is the Japanese word (production/recall).
    case englishToJapanese = "English → 日本語"
    // Each card/question independently picks one of the two above, drilling both at once.
    case mixed = "Mixed"
    // Each question independently picks a (prompt, answer) pair from {kanji, kana, meaning},
    // e.g. kanji→kana, kana→meaning, meaning→kanji — a superset of the JP/English split above,
    // since it also drills kanji↔kana directly with no English involved. Default for Multiple
    // Choice (see `MultipleChoiceView`); `japaneseForm` is ignored while this is selected, since
    // this mode picks the JP script per-question instead of using one fixed form throughout.
    case mixedFields = "Mixed (Kanji/Kana/Meaning)"
    var id: String { rawValue }

    // Flashcards' face model only knows English vs. one fixed Japanese form (see
    // `FlashcardCard.FlashcardFaceContent`); it has no notion of a kanji-only/kana-only card
    // face, so `.mixedFields` is Multiple-Choice-only and left out of Flashcards' picker.
    static let flashcardCases: [StudyDirection] = [.japaneseToEnglish, .englishToJapanese, .mixed]

    // Resolves `.mixed` to a concrete direction deterministically per item, so a card doesn't
    // flip its prompt/answer between re-renders. `seed` is typically the word's entry id.
    func resolved(seed: Int64) -> StudyDirection {
        switch self {
        case .japaneseToEnglish, .englishToJapanese, .mixedFields: return self
        case .mixed: return seed % 2 == 0 ? .japaneseToEnglish : .englishToJapanese
        }
    }
}

// One of the three fields a word can be quizzed on. Distinct from `StudyJapaneseForm`: that axis
// picks how the JP side is *rendered* under a fixed direction; this one is a field in its own
// right, so kanji and kana can each be a prompt or an answer independently, with no English side
// involved at all.
enum StudyField: String, CaseIterable {
    case kanji, kana, meaning

    // All ordered (prompt, answer) pairs where the two sides differ — the 6 combinations the
    // user drills under `.mixedFields` (kanji→kana, kanji→meaning, kana→kanji, kana→meaning,
    // meaning→kanji, meaning→kana).
    private static let pairs: [(StudyField, StudyField)] = {
        var result: [(StudyField, StudyField)] = []
        for prompt in StudyField.allCases {
            for answer in StudyField.allCases where answer != prompt {
                result.append((prompt, answer))
            }
        }
        return result
    }()

    // Deterministically picks one of the 6 (prompt, answer) pairs per item, so a question doesn't
    // change shape between re-renders. `seed` is typically the word's entry id.
    static func randomPair(seed: Int64) -> (prompt: StudyField, answer: StudyField) {
        let index = Int(seed % Int64(pairs.count) + Int64(pairs.count)) % pairs.count
        return pairs[index]
    }
}

// Shared "how is the Japanese side written" axis. Orthogonal to `StudyDirection`.
enum StudyJapaneseForm: String, CaseIterable, Identifiable {
    // The form exactly as it appeared in the source note (the saved surface, possibly inflected).
    case original = "原文"
    // The dictionary kanji headword (canonical written form), falling back to the surface.
    case kanji = "漢字"
    // The kana reading.
    case kana = "かな"
    var id: String { rawValue }
}
