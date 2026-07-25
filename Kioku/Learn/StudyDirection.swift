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

// One of the 6 concrete (prompt, answer) field pairs a word can be quizzed on — the same
// combinations `StudyField.randomPair` produces, given a stable name so per-word evidence can be
// tracked per direction (see `ReviewWordStats.directionStats`) independently of the single
// whole-word SRS streak. Persisted via `rawValue` in `ReviewWordStats`, so cases must not be
// renamed/removed without a migration.
enum QuestionDirection: String, Codable, CaseIterable, Hashable {
    case kanjiToMeaning, kanaToMeaning, kanjiToKana
    case meaningToKanji, meaningToKana, kanaToKanji

    // Recognition: reading Japanese script and producing/picking the meaning, or reading kanji
    // and producing/picking its kana. The "easier" half — no free production of Japanese script.
    static let tier1: [QuestionDirection] = [.kanjiToMeaning, .kanaToMeaning, .kanjiToKana]
    // Production: starting from the meaning (or kana) and producing Japanese script.
    static let tier2: [QuestionDirection] = [.meaningToKanji, .meaningToKana, .kanaToKanji]

    // Maps a `StudyField.randomPair` prompt/answer pair to its named direction. Returns nil for
    // same-field pairs (never produced by `randomPair`, which always picks distinct fields).
    init?(prompt: StudyField, answer: StudyField) {
        switch (prompt, answer) {
        case (.kanji, .meaning): self = .kanjiToMeaning
        case (.kana, .meaning): self = .kanaToMeaning
        case (.kanji, .kana): self = .kanjiToKana
        case (.meaning, .kanji): self = .meaningToKanji
        case (.meaning, .kana): self = .meaningToKana
        case (.kana, .kanji): self = .kanaToKanji
        default: return nil
        }
    }

    // Resolves the direction actually shown to the user under the JP/English `StudyDirection`
    // axis (as opposed to `.mixedFields`, which already carries an explicit field pair and should
    // be resolved via `init(prompt:answer:)` instead). `resolved` must already have `.mixed`
    // resolved to a concrete case (see `StudyDirection.resolved(seed:)`). `isKanaOnlySurface`
    // disambiguates the `.original` form, which doesn't commit to kanji vs. kana on its own.
    static func forJapaneseEnglishAxis(
        resolved: StudyDirection,
        form: StudyJapaneseForm,
        isKanaOnlySurface: Bool
    ) -> QuestionDirection? {
        let field: StudyField = (form == .kana || (form == .original && isKanaOnlySurface)) ? .kana : .kanji
        switch resolved {
        case .japaneseToEnglish: return QuestionDirection(prompt: field, answer: .meaning)
        case .englishToJapanese: return QuestionDirection(prompt: .meaning, answer: field)
        case .mixed, .mixedFields: return nil
        }
    }
}
