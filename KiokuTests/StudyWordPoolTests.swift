import XCTest
@testable import Kioku

// Characterizes StudyWordPool — the shared rule deciding which saved words a Learn-tab session may
// draw from. The learned exclusion lives here precisely because three modes need it and used to
// have zero copies of it, so these cases pin the exclusion, its composition with the note/JLPT/scope
// filters, the held-back count that falls out of the same pass, and the hint built from it.
final class StudyWordPoolTests: XCTestCase {

    private let noteA = UUID()
    private let noteB = UUID()

    // Builds a saved word with just the fields this rule reads.
    private func word(_ id: Int64, notes: [UUID] = []) -> SavedWord {
        SavedWord(canonicalEntryID: id, surface: "w\(id)", sourceNoteIDs: notes)
    }

    // Runs the full selection with sensible defaults, so each case only spells out what it varies.
    private func matching(
        _ words: [SavedWord],
        scope: FlashcardScope = .all,
        noteIDs: Set<UUID> = [],
        jlptLevels: Set<Int> = [],
        excludeLearned: Bool = true,
        jlptLevel: @escaping (Int64) -> Int? = { _ in nil },
        stage: @escaping (Int64) -> MasteryStage = { _ in .new },
        isDue: @escaping (Int64) -> Bool = { _ in true },
        isMarkedWrong: @escaping (Int64) -> Bool = { _ in false }
    ) -> [Int64] {
        StudyWordPool.matching(
            words: words, scope: scope, noteIDs: noteIDs, jlptLevels: jlptLevels,
            excludeLearned: excludeLearned, jlptLevel: jlptLevel, stage: stage,
            isDue: isDue, isMarkedWrong: isMarkedWrong
        ).words.map(\.canonicalEntryID)
    }

    // The count the exclusion held back for the same defaults, for the hidden-count cases.
    private func hiddenLearnedCount(
        _ words: [SavedWord],
        scope: FlashcardScope = .all,
        stage: @escaping (Int64) -> MasteryStage = { _ in .new },
        isDue: @escaping (Int64) -> Bool = { _ in true },
        isMarkedWrong: @escaping (Int64) -> Bool = { _ in false }
    ) -> Int {
        StudyWordPool.matching(
            words: words, scope: scope, noteIDs: [], jlptLevels: [],
            excludeLearned: true, jlptLevel: { _ in nil }, stage: stage,
            isDue: isDue, isMarkedWrong: isMarkedWrong
        ).hiddenLearnedCount
    }

    // MARK: - Learned exclusion

    // The reported bug: a word marked learned still turned up in study sets. Both terminal stages
    // are excluded; New and Learning stay.
    func testExcludesLearnedAndMasteredWords() {
        let stages: [Int64: MasteryStage] = [1: .new, 2: .learning, 3: .learned, 4: .mastered]
        let result = matching(
            [word(1), word(2), word(3), word(4)],
            stage: { stages[$0] ?? .new }
        )
        XCTAssertEqual(result, [1, 2])
    }

    // Turning the setting off restores the old behavior — every stage is eligible.
    func testKeepsLearnedWordsWhenExclusionDisabled() {
        let stages: [Int64: MasteryStage] = [1: .new, 2: .learned, 3: .mastered]
        let result = matching(
            [word(1), word(2), word(3)],
            excludeLearned: false,
            stage: { stages[$0] ?? .new }
        )
        XCTAssertEqual(result, [1, 2, 3])
    }

    // Exclusion applies inside every scope, not just "All" — a learned word that happens to be due
    // is still a word the user said they're done with.
    func testExcludesLearnedWordsWithinTheDueScope() {
        let stages: [Int64: MasteryStage] = [1: .learning, 2: .learned]
        let result = matching(
            [word(1), word(2)],
            scope: .dueNow,
            stage: { stages[$0] ?? .new },
            isDue: { _ in true }
        )
        XCTAssertEqual(result, [1])
    }

    // Same for the marked-wrong scope: being flagged wrong doesn't re-admit a learned word.
    func testExcludesLearnedWordsWithinTheMarkedWrongScope() {
        let stages: [Int64: MasteryStage] = [1: .new, 2: .learned]
        let result = matching(
            [word(1), word(2)],
            scope: .markedWrong,
            stage: { stages[$0] ?? .new },
            isMarkedWrong: { _ in true }
        )
        XCTAssertEqual(result, [1])
    }

    // MARK: - Filters compose

    // Note filter ANDs with the exclusion rather than bypassing it.
    func testNoteFilterAndsWithLearnedExclusion() {
        let stages: [Int64: MasteryStage] = [2: .learned]
        let result = matching(
            [word(1, notes: [noteA]), word(2, notes: [noteA]), word(3, notes: [noteB])],
            noteIDs: [noteA],
            stage: { stages[$0] ?? .new }
        )
        XCTAssertEqual(result, [1])
    }

    // JLPT filter likewise; a word with no level at all is dropped when a level filter is active.
    func testJLPTFilterAndsWithLearnedExclusion() {
        let levels: [Int64: Int] = [1: 5, 2: 5, 3: 4]
        let stages: [Int64: MasteryStage] = [2: .learned]
        let result = matching(
            [word(1), word(2), word(3), word(4)],
            jlptLevels: [5],
            jlptLevel: { levels[$0] },
            stage: { stages[$0] ?? .new }
        )
        XCTAssertEqual(result, [1])
    }

    // With no filters and no exclusions, order is preserved — sessions shuffle downstream, so the
    // pool itself must stay a stable, predictable list.
    func testPreservesInputOrder() {
        XCTAssertEqual(matching([word(3), word(1), word(2)]), [3, 1, 2])
    }

    // MARK: - Scope counts

    // The scope-picker counts run through the same exclusion as the session, so a count can never
    // advertise cards the session would then refuse to deal.
    func testScopedCountsExcludeLearnedWords() {
        let stages: [Int64: MasteryStage] = [1: .new, 2: .learned, 3: .mastered]
        let scoped = StudyWordPool.scoped(
            words: [word(1), word(2), word(3)],
            scope: .all,
            excludeLearned: true,
            stage: { stages[$0] ?? .new },
            isDue: { _ in true },
            isMarkedWrong: { _ in false }
        )
        XCTAssertEqual(scoped.words.map(\.canonicalEntryID), [1])
        XCTAssertEqual(scoped.hiddenLearnedCount, 2, "both dropped words are reported as held back")
    }

    // MARK: - Hint

    // The held-back count comes out of the same pass that produces the pool, so the home screens
    // never re-run the filter just to explain a shrunken count.
    func testSelectionReportsHowManyLearnedWordsWereHeldBack() {
        let stages: [Int64: MasteryStage] = [1: .new, 2: .learned, 3: .mastered, 4: .learning]
        XCTAssertEqual(hiddenLearnedCount([word(1), word(2), word(3), word(4)], stage: { stages[$0] ?? .new }), 2)
    }

    // The count is scoped, not global: under Due it reports the learned words that are actually
    // due, since those are the ones the user is being told about.
    func testHeldBackCountIsScoped() {
        let stages: [Int64: MasteryStage] = [1: .learned, 2: .learned]
        let due: Set<Int64> = [1]
        let hidden = hiddenLearnedCount(
            [word(1), word(2)],
            scope: .dueNow,
            stage: { stages[$0] ?? .new },
            isDue: { due.contains($0) }
        )
        XCTAssertEqual(hidden, 1)
    }

    // Nothing is reported as held back when the exclusion is off.
    func testNothingHeldBackWhenExclusionDisabled() {
        let selection = StudyWordPool.matching(
            words: [word(1), word(2)], scope: .all, noteIDs: [], jlptLevels: [],
            excludeLearned: false, jlptLevel: { _ in nil }, stage: { _ in .learned },
            isDue: { _ in true }, isMarkedWrong: { _ in false }
        )
        XCTAssertEqual(selection.hiddenLearnedCount, 0)
        XCTAssertEqual(selection.words.count, 2)
    }

    // The home screens explain a shrunken count only when the exclusion is what shrank it.
    func testHintNamesHowManyLearnedWordsAreHidden() {
        XCTAssertEqual(
            StudyWordPool.learnedExclusionHint(hiddenLearnedCount: 3),
            "3 learned words hidden. Turn off “Skip learned words” in Settings to review them anyway."
        )
    }

    // Singular wording for exactly one hidden word.
    func testHintUsesSingularForOneHiddenWord() {
        XCTAssertEqual(
            StudyWordPool.learnedExclusionHint(hiddenLearnedCount: 1),
            "1 learned word hidden. Turn off “Skip learned words” in Settings to review them anyway."
        )
    }

    // No hint when nothing was held back — the shortfall has some other cause, and the mode's own
    // message already covers it.
    func testNoHintWhenNothingHeldBack() {
        XCTAssertNil(StudyWordPool.learnedExclusionHint(hiddenLearnedCount: 0))
    }

    // MARK: - Stage predicate

    // The stage predicate the exclusion is built on, pinned directly so a future MasteryStage case
    // has to make an explicit decision here rather than silently defaulting into study sets.
    func testStudiableStages() {
        XCTAssertTrue(StudyWordPool.isStudiable(.new))
        XCTAssertTrue(StudyWordPool.isStudiable(.learning))
        XCTAssertFalse(StudyWordPool.isStudiable(.learned))
        XCTAssertFalse(StudyWordPool.isStudiable(.mastered))
    }
}
