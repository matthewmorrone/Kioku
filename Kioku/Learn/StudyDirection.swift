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
    var id: String { rawValue }

    // Resolves `.mixed` to a concrete direction deterministically per item, so a card doesn't
    // flip its prompt/answer between re-renders. `seed` is typically the word's entry id.
    func resolved(seed: Int64) -> StudyDirection {
        switch self {
        case .japaneseToEnglish, .englishToJapanese: return self
        case .mixed: return seed % 2 == 0 ? .japaneseToEnglish : .englishToJapanese
        }
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
