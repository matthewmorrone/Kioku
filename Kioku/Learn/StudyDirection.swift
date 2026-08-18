import Foundation

// One of the three fields a word can be quizzed on. Kanji and kana are fields in their own right,
// so either can be a prompt or an answer independently, with no English side involved at all.
enum StudyField: String, CaseIterable {
    case kanji, kana, meaning
}

// The 6 concrete (prompt, answer) field pairs a word can be quizzed on — the single direction
// model shared by Flashcards, Multiple Choice, and Fill in the Blank. Each carries its own
// evidence in `ReviewWordStats.directionStats`, so mastery can require each direction to clear
// independently rather than being satisfied by a streak in just one.
//
// Persisted via `rawValue` in `ReviewWordStats` and in each activity's saved direction selection,
// so cases must not be renamed/removed without a migration. `nonisolated` (like
// `ScriptClassifier`/`KanaNormalizer`) since it's a pure, stateless mapping with no MainActor
// state — callable from any context, including plain (non-`@MainActor`) unit tests.
nonisolated enum QuestionDirection: String, Codable, CaseIterable, Hashable, Identifiable {
    case kanjiToMeaning, kanaToMeaning, kanjiToKana
    case meaningToKanji, meaningToKana, kanaToKanji

    var id: String { rawValue }

    // Recognition: reading Japanese script and producing the meaning, or reading kanji and
    // producing its kana. The "easier" half — no free production of Japanese script. Clearing all
    // of these (that apply to the word) is the Learned bar.
    static let tier1: [QuestionDirection] = [.kanjiToMeaning, .kanaToMeaning, .kanjiToKana]
    // Production: starting from the meaning (or kana) and producing Japanese script. Clearing
    // these on top of tier1 is the Mastered bar.
    static let tier2: [QuestionDirection] = [.meaningToKanji, .meaningToKana, .kanaToKanji]

    // Picker label, reading as the prompt → answer pair the user will actually see.
    var label: String {
        switch self {
        case .kanjiToMeaning: return "漢字 → English"
        case .kanaToMeaning:  return "かな → English"
        case .kanjiToKana:    return "漢字 → かな"
        case .meaningToKanji: return "English → 漢字"
        case .meaningToKana:  return "English → かな"
        case .kanaToKanji:    return "かな → 漢字"
        }
    }

    // Which mastery stage this direction's evidence counts toward — the recognition/production
    // split above, surfaced for grouping the picker into sections.
    var stage: MasteryStage {
        QuestionDirection.tier1.contains(self) ? .learned : .mastered
    }

    // True when 漢字 sits on either side, so this can only be asked of a word that has a kanji
    // form. Drives both pool eligibility and the promotion bars.
    var requiresKanji: Bool {
        let pair = fields
        return pair.prompt == .kanji || pair.answer == .kanji
    }

    // True when the answer is English prose rather than Japanese script. Typed grading has to
    // compare these against the word's whole gloss set instead of one expected string, since
    // "to eat" / "eat" / "eating" are all the same answer (see `AnswerScorer.grade(input:glosses:)`).
    var answerIsMeaning: Bool { fields.answer == .meaning }

    // Narrows a direction list to the ones a word can actually be quizzed in. A kana-only word
    // (こと, きれい, most loanwords) has no kanji form to read or produce, so all four kanji
    // directions are unaskable for it — leaving them in the promotion bar would strand it below
    // Learned forever, since a direction that's never asked can never accumulate evidence. What's
    // left for such a word is かな→English (recognition) and English→かな (production), one on
    // each side of the Learned/Mastered split.
    static func applicable(_ directions: [QuestionDirection], hasKanjiForm: Bool) -> [QuestionDirection] {
        hasKanjiForm ? directions : directions.filter { $0.requiresKanji == false }
    }

    // Maps a prompt/answer field pair to its named direction. Returns nil for same-field pairs,
    // which name no direction.
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

    // The inverse of `init(prompt:answer:)` — the concrete field pair this direction quizzes.
    var fields: (prompt: StudyField, answer: StudyField) {
        switch self {
        case .kanjiToMeaning: return (.kanji, .meaning)
        case .kanaToMeaning: return (.kana, .meaning)
        case .kanjiToKana: return (.kanji, .kana)
        case .meaningToKanji: return (.meaning, .kanji)
        case .meaningToKana: return (.meaning, .kana)
        case .kanaToKanji: return (.kana, .kanji)
        }
    }
}

// The subset of directions a session draws from — the shared replacement for the per-activity
// "Direction" menus, each of which had its own enum with its own magic "Mixed" case. A subset
// expresses all of those (one ticked = the old fixed direction, all ticked = the old Mixed) and
// also the combinations they couldn't, like "exactly the three that gate Learned".
//
// `RawRepresentable` over a comma-joined list of `QuestionDirection.rawValue` so it can be stored
// directly in `@AppStorage`; unknown tokens are dropped on read, so a selection saved by a build
// with different cases still loads.
struct DirectionSelection: RawRepresentable, Equatable {
    var directions: Set<QuestionDirection>

    // Every direction — the default for a new session, and what the old "Mixed" case meant.
    static let all = DirectionSelection(directions: Set(QuestionDirection.allCases))

    init(directions: Set<QuestionDirection>) {
        self.directions = directions
    }

    init(rawValue: String) {
        directions = Set(rawValue.split(separator: ",").compactMap { QuestionDirection(rawValue: String($0)) })
    }

    // Serialized in `allCases` order rather than Set iteration order, so the stored string is
    // stable across launches instead of churning UserDefaults on every write.
    var rawValue: String {
        QuestionDirection.allCases.filter { directions.contains($0) }.map(\.rawValue).joined(separator: ",")
    }

    // Nothing ticked means nothing can be asked; hosts use this to disable Start.
    var isEmpty: Bool { directions.isEmpty }

    // True when every ticked direction needs a kanji form, which is what makes a kana-only word
    // ineligible for the session entirely rather than merely limited within it.
    var requiresKanjiThroughout: Bool {
        directions.isEmpty == false && directions.allSatisfy(\.requiresKanji)
    }

    // The ticked directions a word with this kanji-form status can actually be asked, in a stable
    // order. Empty means the word can't be asked anything in this session and should be dropped
    // from the pool.
    func askable(hasKanjiForm: Bool) -> [QuestionDirection] {
        QuestionDirection.applicable(
            QuestionDirection.allCases.filter { directions.contains($0) },
            hasKanjiForm: hasKanjiForm
        )
    }

    // Picks one of the word's askable directions deterministically, so a question doesn't change
    // shape between re-renders. `seed` is the word's entry id. Nil when the word can't be asked
    // anything in this session.
    func resolved(seed: Int64, hasKanjiForm: Bool) -> QuestionDirection? {
        let options = askable(hasKanjiForm: hasKanjiForm)
        guard options.isEmpty == false else { return nil }
        let index = Int(seed % Int64(options.count) + Int64(options.count)) % options.count
        return options[index]
    }
}
