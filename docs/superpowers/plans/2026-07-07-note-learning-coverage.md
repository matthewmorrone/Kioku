# Note Learning-Coverage Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fifth "Coverage" page to the Learn tab that shows a picked note's saved vocabulary grouped by JLPT level × mastery stage (New/Learning/Learned), with a coverage % and due count, where tapping a group launches a scoped Flashcards or Multiple Choice session.

**Architecture:** A single canonical `MasteryStage` derivation on `ReviewStore` (the one definition of New/Learning/Learned, built on the existing configurable `AutoLearnPolicy`); a pure, closure-injected `NoteCoverageCalculator` that produces a testable grid; a SwiftUI `CoverageView` (note picker → breakdown) wired as `LearnPage.coverage`; and an optional preset-session entry point on `FlashcardsView`/`MultipleChoiceView` so a coverage cell can hand its exact `[SavedWord]` set to a mode, skipping that mode's home pickers.

**Tech Stack:** Swift 6, SwiftUI, XCTest. Stores are `@MainActor ObservableObject`s keyed by `SavedWord.canonicalEntryID: Int64`. Tests inject a per-suite `UserDefaults`.

**Spec:** `docs/superpowers/specs/2026-07-07-note-learning-coverage-design.md`

**Test command:** Run the `KiokuTests` suite via the `xcode` MCP `test_sim` tool (session defaults already select the project/scheme/simulator), or `xcodebuild test -scheme Kioku -destination 'platform=iOS Simulator,name=iPhone 16'`. Filter to a class by appending `-only-testing:KiokuTests/<ClassName>` to the `xcodebuild` form. Adjust the simulator name to one that exists locally (`xcrun simctl list devices available`).

**Note on invariants:** This repo's pre-commit hook requires an intent comment (`//`) directly above every function/type and warns past 800 lines/file. Every new type and function below carries its comment. Commit messages end with the `Co-Authored-By` trailer used across this repo.

---

## Phase 1 — Shared mastery model on ReviewStore

### Task 1: `MasteryStage` enum + `masteryStage(for:)`

**Files:**
- Create: `Kioku/Learn/MasteryStage.swift`
- Modify: `Kioku/Learn/Flashcards/ReviewStore.swift` (add method near `learnedState(for:)`, ~line 100)
- Test: `KiokuTests/ReviewStoreMasteryTests.swift`

- [ ] **Step 1: Write the failing test**

Create `KiokuTests/ReviewStoreMasteryTests.swift`:

```swift
import XCTest
@testable import Kioku

// Verifies ReviewStore's canonical mastery-stage derivation: New (untouched), Learning
// (engaged but below the learned bar), Learned (marked/auto-promoted), plus the disjoint
// due-for-review overlay.
@MainActor
final class ReviewStoreMasteryTests: XCTestCase {
    private var suiteName: String = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "kioku-mastery-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // A never-reviewed, unmarked word is New.
    func testNewWhenUntouched() {
        let store = ReviewStore(userDefaults: defaults)
        XCTAssertEqual(store.masteryStage(for: 1), .new)
    }

    // A reviewed-but-not-yet-learned word is Learning (auto-learn is off by default so a
    // single correct answer does not promote it).
    func testLearningAfterReview() {
        let store = ReviewStore(userDefaults: defaults)
        store.recordCorrect(for: 1)
        XCTAssertEqual(store.masteryStage(for: 1), .learning)
    }

    // Manually marking "not learned" with no review history still counts as engagement → Learning.
    func testLearningWhenManuallyNotLearned() {
        let store = ReviewStore(userDefaults: defaults)
        store.setLearnedState(.notLearned, for: 1)
        XCTAssertEqual(store.masteryStage(for: 1), .learning)
    }

    // An explicitly-learned word is Learned.
    func testLearnedWhenMarked() {
        let store = ReviewStore(userDefaults: defaults)
        store.setLearnedState(.learned, for: 1)
        XCTAssertEqual(store.masteryStage(for: 1), .learned)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run the `ReviewStoreMasteryTests` class.
Expected: compile failure — `masteryStage(for:)` and `MasteryStage` do not exist yet.

- [ ] **Step 3: Create the `MasteryStage` type**

Create `Kioku/Learn/MasteryStage.swift`:

```swift
import Foundation

// The single canonical "how well does the user know this word?" progression, shared app-wide and
// derived on ReviewStore (see ReviewStore.masteryStage(for:)). New → Learning → Learned. "Due for
// review" is a separate orthogonal flag (ReviewStore.isDueForReview), NOT a fourth stage.
enum MasteryStage: Hashable, CaseIterable {
    // Never reviewed and not manually marked either way.
    case new
    // Engaged — reviewed at least once, or explicitly marked "not learned" — but below the bar.
    case learning
    // Cleared the configured auto-learn bar, or manually marked learned.
    case learned
}
```

- [ ] **Step 4: Add `masteryStage(for:)` to ReviewStore**

In `Kioku/Learn/Flashcards/ReviewStore.swift`, immediately after `learnedState(for:)` (the method returning `LearnedState`), add:

```swift
    // The canonical mastery stage for a word — the one definition of New/Learning/Learned used
    // app-wide. Learned wins (manual mark or auto-promotion via AutoLearnPolicy); otherwise any
    // engagement (review stats present, or an explicit not-learned mark) is Learning; a
    // never-touched word is New.
    func masteryStage(for id: Int64) -> MasteryStage {
        if learnedState(for: id) == .learned { return .learned }
        if stats[id] != nil || learnedState(for: id) == .notLearned { return .learning }
        return .new
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run the `ReviewStoreMasteryTests` class.
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Kioku/Learn/MasteryStage.swift Kioku/Learn/Flashcards/ReviewStore.swift KiokuTests/ReviewStoreMasteryTests.swift
git commit -m "feat(learn): canonical MasteryStage derivation on ReviewStore

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 2: `isDueForReview(id:at:)` — the disjoint due overlay

**Files:**
- Modify: `Kioku/Learn/Flashcards/ReviewStore.swift` (add after the existing `isDue(id:at:)`, ~line 140)
- Test: `KiokuTests/ReviewStoreMasteryTests.swift` (extend)

- [ ] **Step 1: Write the failing test**

Append these two methods to `ReviewStoreMasteryTests`:

```swift
    // A never-reviewed word is NOT due-for-review (unlike isDue, which treats it as due). This is
    // what keeps New and Due disjoint on the coverage screen.
    func testNotDueForReviewWhenNeverReviewed() {
        let store = ReviewStore(userDefaults: defaults)
        XCTAssertFalse(store.isDueForReview(id: 1, at: .distantFuture))
    }

    // A reviewed word becomes due-for-review once its scheduled dueDate has passed.
    func testDueForReviewWhenReviewedAndLapsed() {
        let store = ReviewStore(userDefaults: defaults)
        store.recordCorrect(for: 1) // schedules dueDate = now + interval
        XCTAssertTrue(store.isDueForReview(id: 1, at: .distantFuture))
        XCTAssertFalse(store.isDueForReview(id: 1, at: .distantPast))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run the `ReviewStoreMasteryTests` class.
Expected: compile failure — `isDueForReview(id:at:)` does not exist.

- [ ] **Step 3: Add `isDueForReview(id:at:)` to ReviewStore**

In `Kioku/Learn/Flashcards/ReviewStore.swift`, directly after the existing `isDue(id:at:)` method, add:

```swift
    // True only when the word has been reviewed before AND its scheduled interval has lapsed.
    // Unlike `isDue`, a never-reviewed word is NOT due here — the coverage screen keeps New and
    // Due as disjoint categories (New carries its own call-to-action).
    func isDueForReview(id: Int64, at date: Date = Date()) -> Bool {
        guard let st = stats[id], let due = st.dueDate else { return false }
        return due <= date
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run the `ReviewStoreMasteryTests` class.
Expected: PASS (6 tests total).

- [ ] **Step 5: Commit**

```bash
git add Kioku/Learn/Flashcards/ReviewStore.swift KiokuTests/ReviewStoreMasteryTests.swift
git commit -m "feat(learn): isDueForReview overlay disjoint from New

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase 2 — Pure coverage calculation

### Task 3: `NoteCoverage` model + `NoteCoverageCalculator`

**Files:**
- Create: `Kioku/Learn/Coverage/NoteCoverage.swift`
- Test: `KiokuTests/NoteCoverageCalculatorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `KiokuTests/NoteCoverageCalculatorTests.swift`:

```swift
import XCTest
@testable import Kioku

// Verifies the pure coverage aggregation: grouping saved words into a JLPT-level × mastery-stage
// grid, ordering levels easiest→hardest then No-level, and computing totals / coverage % / due count.
final class NoteCoverageCalculatorTests: XCTestCase {

    // Five words across two JLPT levels + a no-level word, with mixed stages and one due word.
    func testGroupsByLevelAndStageWithTotals() {
        let words = (1...5).map { SavedWord(canonicalEntryID: Int64($0), surface: "w\($0)") }
        let level: (Int64) -> Int? = { id in
            switch id {
            case 1, 2: return 5   // N5
            case 3, 5: return 4   // N4
            default:   return nil // No level
            }
        }
        let stage: (Int64) -> MasteryStage = { id in
            switch id {
            case 1, 5: return .learned
            case 3:    return .learning
            default:   return .new
            }
        }
        let isDue: (Int64) -> Bool = { $0 == 5 }

        let cov = NoteCoverageCalculator.compute(words: words, level: level, stage: stage, isDue: isDue)

        XCTAssertEqual(cov.total, 5)
        XCTAssertEqual(cov.learnedCount, 2)
        XCTAssertEqual(cov.dueCount, 1)
        XCTAssertEqual(cov.coverageFraction, 0.4, accuracy: 0.0001)
        // Levels ordered N5 (5) → N4 (4) → No level (nil).
        XCTAssertEqual(cov.levels.map(\.level), [5, 4, nil])
        let n5 = cov.levels[0]
        XCTAssertEqual(n5.total, 2)
        XCTAssertEqual(n5.learnedCount, 1)
        XCTAssertEqual(n5.words(in: .learned).map(\.canonicalEntryID), [1])
        XCTAssertEqual(n5.words(in: .new).map(\.canonicalEntryID), [2])
    }

    // An empty note has zero coverage and no level rows (no divide-by-zero).
    func testEmptyNoteHasZeroCoverage() {
        let cov = NoteCoverageCalculator.compute(
            words: [], level: { _ in nil }, stage: { _ in .new }, isDue: { _ in false }
        )
        XCTAssertEqual(cov.total, 0)
        XCTAssertEqual(cov.learnedCount, 0)
        XCTAssertEqual(cov.coverageFraction, 0)
        XCTAssertTrue(cov.levels.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run the `NoteCoverageCalculatorTests` class.
Expected: compile failure — `NoteCoverage` / `NoteCoverageCalculator` do not exist.

- [ ] **Step 3: Create the model + calculator**

Create `Kioku/Learn/Coverage/NoteCoverage.swift`:

```swift
import Foundation

// The computed learning-coverage grid for a single note: its saved words grouped by JLPT level
// and, within each level, by mastery stage, plus note-wide totals. Pure value type produced by
// NoteCoverageCalculator so it is unit-testable without stores or SwiftUI.
struct NoteCoverage: Equatable {

    // One JLPT-level row of the grid. `level` is the JLPT N-number (5…1) or nil for "No level".
    struct Level: Equatable {
        let level: Int?
        let stageWords: [MasteryStage: [SavedWord]]

        // Total words at this level across all stages.
        var total: Int {
            MasteryStage.allCases.reduce(0) { $0 + (stageWords[$1]?.count ?? 0) }
        }

        // Words at this level that have reached the Learned stage.
        var learnedCount: Int { stageWords[.learned]?.count ?? 0 }

        // The words at this level in a given stage (empty when none).
        func words(in stage: MasteryStage) -> [SavedWord] { stageWords[stage] ?? [] }
    }

    // Level rows, ordered easiest → hardest (N5→N1) then No level; only non-empty levels appear.
    let levels: [Level]
    // Total saved words in the note.
    let total: Int
    // How many of them are Learned.
    let learnedCount: Int
    // How many are due for review right now (disjoint from New; see ReviewStore.isDueForReview).
    let dueCount: Int

    // Note-wide learned fraction (0…1); 0 when the note has no words.
    var coverageFraction: Double {
        total == 0 ? 0 : Double(learnedCount) / Double(total)
    }
}

// Builds a NoteCoverage from a word list plus injected lookups. Closures (rather than concrete
// stores) keep it pure and testable: production passes dictionaryStore.jlptLevel / reviewStore
// derivations; tests pass deterministic stubs.
enum NoteCoverageCalculator {

    // Groups words into the (level × stage) grid and tallies note-wide totals. Levels are ordered
    // easiest→hardest (higher N-number first) with No-level (nil) last, and empty levels omitted.
    static func compute(
        words: [SavedWord],
        level: (Int64) -> Int?,
        stage: (Int64) -> MasteryStage,
        isDue: (Int64) -> Bool
    ) -> NoteCoverage {
        var byLevel: [Int?: [MasteryStage: [SavedWord]]] = [:]
        var learnedCount = 0
        var dueCount = 0

        for word in words {
            let id = word.canonicalEntryID
            let lv = level(id)
            let st = stage(id)
            byLevel[lv, default: [:]][st, default: []].append(word)
            if st == .learned { learnedCount += 1 }
            if isDue(id) { dueCount += 1 }
        }

        // Order: non-nil descending (N5=5 … N1=1), then No level (nil) last.
        let orderedKeys = byLevel.keys.sorted { a, b in
            switch (a, b) {
            case let (x?, y?): return x > y
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return false
            }
        }

        let levels = orderedKeys.map { key in
            NoteCoverage.Level(level: key, stageWords: byLevel[key] ?? [:])
        }

        return NoteCoverage(
            levels: levels,
            total: words.count,
            learnedCount: learnedCount,
            dueCount: dueCount
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the `NoteCoverageCalculatorTests` class.
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Kioku/Learn/Coverage/NoteCoverage.swift KiokuTests/NoteCoverageCalculatorTests.swift
git commit -m "feat(learn): pure NoteCoverage grid calculator

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase 3 — Coverage screen + Learn page

### Task 4: Preset entry points on FlashcardsView and MultipleChoiceView

*(Built before the coverage UI so the UI can present them. Pure additive change — default `nil` keeps the existing pager call sites working.)*

**Files:**
- Modify: `Kioku/Learn/Flashcards/FlashcardsView.swift`
- Modify: `Kioku/Learn/MultipleChoice/MultipleChoiceView.swift`

- [ ] **Step 1: Add a preset property + auto-start to FlashcardsView**

In `Kioku/Learn/Flashcards/FlashcardsView.swift`, add a stored property just below the existing
`var kanjiReadingFallback: KanjiReadingFallbackMap = KanjiReadingFallbackMap()` line:

```swift
    // When non-nil, this view opens directly into a session over exactly these words (skipping the
    // home pickers) — used by the Coverage screen to drill a specific level × stage word set.
    var presetWords: [SavedWord]? = nil
```

Then add a one-shot guard property with the other `@State` declarations:

```swift
    // Ensures the preset session auto-starts only once, so ending it doesn't immediately restart.
    @State private var didAutoStartPreset: Bool = false
```

- [ ] **Step 2: Wire the auto-start on appear**

In `FlashcardsView.body`, attach an `.onAppear` to the outer `NavigationStack` (alongside the
existing `.preference(...)` / `.sheet(...)` modifiers on the body). Add:

```swift
        .onAppear {
            // Preset launch (from Coverage): seed the pool with the handed-in words and start once.
            if let presetWords, didAutoStartPreset == false {
                didAutoStartPreset = true
                sessionSource = presetWords
                startSession()
            }
        }
```

This reuses the existing `sessionSource` → `startSession()` path (which shuffles + applies
`cardCount`), so no session internals change.

- [ ] **Step 3: Mirror the same on MultipleChoiceView**

In `Kioku/Learn/MultipleChoice/MultipleChoiceView.swift`, add below its
`let segmenter: (any TextSegmenting)?` declaration:

```swift
    // When non-nil, opens directly into a scoped session over these words (Coverage drill-down).
    var presetWords: [SavedWord]? = nil
```

Add with the other `@State`:

```swift
    // Guards the preset auto-start so it fires exactly once.
    @State private var didAutoStartPreset: Bool = false
```

Refactor `startSessionFromHome()` (line ~320) to delegate to a word-set entry point, so the home
picker and the preset launch share one code path (DRY). Replace the existing method:

```swift
    // Resolves the question pool asynchronously, then activates the session.
    private func startSessionFromHome() {
        let words = wordsMatchingSelection()
        sessionActive = true
        isResolving = true
        sessionCorrect = 0
        sessionWrong = 0
        index = 0
        selected = nil
        questions = []
        let dir = direction
        let form = japaneseForm
        let limit = questionCount
        Task {
            let items = await resolveItems(for: words)
            let built = buildQuestions(from: items, direction: dir, japaneseForm: form)
            // A positive limit caps the quiz; 0 (or blank field) means quiz everything.
            questions = limit > 0 ? Array(built.prefix(limit)) : built
            isResolving = false
        }
    }
```

with:

```swift
    // Resolves the question pool asynchronously, then activates the session.
    private func startSessionFromHome() {
        startSession(with: wordsMatchingSelection())
    }

    // Builds and activates a session over an explicit word set — shared by the home picker and by
    // the Coverage screen's scoped launch.
    private func startSession(with words: [SavedWord]) {
        sessionActive = true
        isResolving = true
        sessionCorrect = 0
        sessionWrong = 0
        index = 0
        selected = nil
        questions = []
        let dir = direction
        let form = japaneseForm
        let limit = questionCount
        Task {
            let items = await resolveItems(for: words)
            let built = buildQuestions(from: items, direction: dir, japaneseForm: form)
            // A positive limit caps the quiz; 0 (or blank field) means quiz everything.
            questions = limit > 0 ? Array(built.prefix(limit)) : built
            isResolving = false
        }
    }
```

Then attach the auto-start to `MultipleChoiceView.body`:

```swift
        .onAppear {
            if let presetWords, didAutoStartPreset == false {
                didAutoStartPreset = true
                startSession(with: presetWords)
            }
        }
```

- [ ] **Step 4: Build to verify it compiles**

Build the `Kioku` scheme for the simulator (via `xcode` MCP `build_sim`, or `xcodebuild build -scheme Kioku -destination 'platform=iOS Simulator,name=iPhone 16'`).
Expected: BUILD SUCCEEDED. (Existing `FlashcardsView(...)` / `MultipleChoiceView(...)` call sites in `CardsTabView.swift` still compile because `presetWords` defaults to `nil`.)

- [ ] **Step 5: Commit**

```bash
git add Kioku/Learn/Flashcards/FlashcardsView.swift Kioku/Learn/MultipleChoice/MultipleChoiceView.swift
git commit -m "feat(learn): optional preset-session entry for Flashcards and Multiple Choice

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 5: `CoverageDetailView` — the per-note breakdown + tap-to-study

**Files:**
- Create: `Kioku/Learn/Coverage/CoverageDetailView.swift`

- [ ] **Step 1: Create the detail view**

Create `Kioku/Learn/Coverage/CoverageDetailView.swift`:

```swift
import SwiftUI

// Which study mode a coverage-cell tap launches. Cloze is intentionally excluded — it is
// sentence-based and has no saved-word-set selection model (see the design spec).
enum CoverageStudyMode: Identifiable {
    case flashcards
    case multipleChoice
    var id: Int { self == .flashcards ? 0 : 1 }
}

// A pending scoped-study launch: the exact words a tapped cell resolved, plus the chosen mode.
struct CoverageLaunch: Identifiable {
    let id = UUID()
    let words: [SavedWord]
    let mode: CoverageStudyMode
}

// The per-note learning-coverage breakdown: a summary header (learned %, due count) and one row
// per JLPT level, each split into tappable New/Learning/Learned stage chips that launch a scoped
// Flashcards or Multiple Choice session over exactly that cell's words.
struct CoverageDetailView: View {
    let note: Note
    let dictionaryStore: DictionaryStore?

    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var notesStore: NotesStore
    @EnvironmentObject private var reviewStore: ReviewStore

    @State private var pendingWords: [SavedWord] = []
    @State private var showModeChooser = false
    @State private var launch: CoverageLaunch?

    // The live coverage grid for this note, recomputed from the stores on each render.
    private var coverage: NoteCoverage {
        let words = wordsStore.words.filter { $0.sourceNoteIDs.contains(note.id) }
        return NoteCoverageCalculator.compute(
            words: words,
            level: { dictionaryStore?.jlptLevel(for: $0) },
            stage: { reviewStore.masteryStage(for: $0) },
            isDue: { reviewStore.isDueForReview(id: $0) }
        )
    }

    var body: some View {
        List {
            summarySection
            ForEach(coverage.levels, id: \.level) { level in
                levelSection(level)
            }
        }
        .navigationTitle(note.title.isEmpty ? "Coverage" : note.title)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Study these words with…", isPresented: $showModeChooser, titleVisibility: .visible) {
            Button("Flashcards") { launch = CoverageLaunch(words: pendingWords, mode: .flashcards) }
            Button("Multiple Choice") { launch = CoverageLaunch(words: pendingWords, mode: .multipleChoice) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $launch) { launch in
            studySheet(for: launch)
        }
    }

    // Note-wide summary: "N of M learned (P%)" with a progress bar, and a due-count callout.
    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(coverage.learnedCount) of \(coverage.total) learned (\(Int((coverage.coverageFraction * 100).rounded()))%)")
                    .font(.headline)
                ProgressView(value: coverage.coverageFraction)
                if coverage.dueCount > 0 {
                    Label("\(coverage.dueCount) due for review", systemImage: "clock.badge.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // One level row: the level label + a "x/y learned" caption + three tappable stage chips.
    private func levelSection(_ level: NoteCoverage.Level) -> some View {
        Section(header: Text(levelTitle(level.level))) {
            HStack {
                Text("\(level.learnedCount)/\(level.total) learned")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 8) {
                stageChip(level, .new, "New")
                stageChip(level, .learning, "Learning")
                stageChip(level, .learned, "Learned")
            }
        }
    }

    // A single tappable stage chip. Tapping a non-empty chip resolves its words and opens the
    // mode chooser; an empty chip is disabled.
    private func stageChip(_ level: NoteCoverage.Level, _ stage: MasteryStage, _ title: String) -> some View {
        let words = level.words(in: stage)
        return Button {
            pendingWords = words
            showModeChooser = true
        } label: {
            VStack(spacing: 2) {
                Text("\(words.count)").font(.headline.monospacedDigit())
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(words.isEmpty)
        .opacity(words.isEmpty ? 0.4 : 1)
    }

    // The presented scoped session, re-injecting the stores the mode views require.
    @ViewBuilder
    private func studySheet(for launch: CoverageLaunch) -> some View {
        switch launch.mode {
        case .flashcards:
            FlashcardsView(dictionaryStore: dictionaryStore, segmenter: nil, presetWords: launch.words)
                .environmentObject(wordsStore)
                .environmentObject(notesStore)
                .environmentObject(reviewStore)
        case .multipleChoice:
            MultipleChoiceView(dictionaryStore: dictionaryStore, segmenter: nil, presetWords: launch.words)
                .environmentObject(wordsStore)
                .environmentObject(notesStore)
                .environmentObject(reviewStore)
        }
    }

    // Human label for a JLPT level row: "N5"…"N1", or "No level" for words not on any list.
    private func levelTitle(_ level: Int?) -> String {
        guard let level else { return "No level" }
        return "N\(level)"
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Build the `Kioku` scheme for the simulator.
Expected: BUILD SUCCEEDED.

*(Note: `MultipleChoiceView`/`FlashcardsView` first init params are `dictionaryStore:` and `segmenter:`; passing `segmenter: nil` matches the pager's usage for MC. If FlashcardsView's `segmenter` is non-optional in a way that rejects `nil`, pass the `dictionaryStore`-scoped segmenter the coverage view receives — but per `CardsTabView.swift` both accept the forwarded optional, so `nil` compiles.)*

- [ ] **Step 3: Commit**

```bash
git add Kioku/Learn/Coverage/CoverageDetailView.swift
git commit -m "feat(learn): per-note coverage breakdown with tap-to-study

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 6: `CoverageView` note picker + wire as `LearnPage.coverage`

**Files:**
- Create: `Kioku/Learn/Coverage/CoverageView.swift`
- Modify: `Kioku/Learn/CardsTabView.swift`

- [ ] **Step 1: Create the coverage home (note picker)**

Create `Kioku/Learn/Coverage/CoverageView.swift`:

```swift
import SwiftUI

// The Learn tab's Coverage page: a list of notes that have saved words; picking one pushes the
// per-note learning-coverage breakdown. Owns its own NavigationStack like the sibling Learn pages.
struct CoverageView: View {
    let dictionaryStore: DictionaryStore?

    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var notesStore: NotesStore

    // Only notes that currently have at least one saved word — the same rule the Words-tab filter
    // uses (WordsFilterView.notesWithSavedWords).
    private var notesWithSavedWords: [Note] {
        let noteIDsWithWords = Set(wordsStore.words.flatMap(\.sourceNoteIDs))
        return notesStore.notes.filter { noteIDsWithWords.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if notesWithSavedWords.isEmpty {
                    ContentUnavailableView(
                        "No notes with saved words",
                        systemImage: "chart.bar.doc.horizontal",
                        description: Text("Save some words from a note to see its learning coverage.")
                    )
                } else {
                    List(notesWithSavedWords) { note in
                        NavigationLink {
                            CoverageDetailView(note: note, dictionaryStore: dictionaryStore)
                        } label: {
                            Text(note.title.isEmpty ? "Untitled" : note.title)
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                LearnHomeTitle(title: "Coverage", systemImage: "chart.bar.doc.horizontal")
            }
        }
    }
}
```

- [ ] **Step 2: Add the `LearnPage.coverage` case**

In `Kioku/Learn/CardsTabView.swift`, add the case to the enum (after `kanaChart`):

```swift
enum LearnPage: Int, CaseIterable, Identifiable {
    case flashcards
    case multipleChoice
    case cloze
    case kanaChart
    case coverage
    var id: Int { rawValue }
}
```

- [ ] **Step 3: Add the page to the pager HStack**

In `LearnPagerView.body`, in the `HStack(spacing: 0)`, after the `KanaChartView().frame(width: width)` line, add:

```swift
                CoverageView(dictionaryStore: dictionaryStore)
                    .frame(width: width)
```

The dot overlay and index clamping read `LearnPage.allCases`, so adding the enum case keeps the dot
count and swipe range in sync automatically.

- [ ] **Step 4: Build to verify it compiles**

Build the `Kioku` scheme for the simulator.
Expected: BUILD SUCCEEDED. The Learn tab now has five swipe pages ending in Coverage.

- [ ] **Step 5: Commit**

```bash
git add Kioku/Learn/Coverage/CoverageView.swift Kioku/Learn/CardsTabView.swift
git commit -m "feat(learn): add Coverage page to the Learn tab pager

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase 4 — End-to-end verification on device

### Task 7: Manual verification of the full flow

**Files:** none (verification only).

- [ ] **Step 1: Build + install + launch on the connected device**

Use the `deploy` skill (build Kioku and install/launch on the connected iPhone), or the `run` skill.

- [ ] **Step 2: Verify the coverage read-path**

1. Open the Learn tab; swipe to the fifth page — confirm five dots and a "Coverage" title.
2. Confirm the note list shows only notes that have saved words.
3. Open a note you have studied; verify:
   - The summary reads "N of M learned (P%)" with a filled progress bar.
   - Level rows appear ordered N5 → N1 → No level, only for levels present in the note.
   - Each level shows "x/y learned" and New/Learning/Learned chips whose counts sum to the level total.
   - A "due for review" callout appears only if some words are lapsed.

- [ ] **Step 3: Verify tap-to-study**

1. Tap a non-empty **Learning** chip → choose **Flashcards** → confirm the session contains exactly that cell's words (count matches the chip).
2. End it; tap a non-empty **New** chip → choose **Multiple Choice** → confirm the scoped session.
3. Confirm an empty (0) chip is not tappable.
4. Answer a few cards correct enough to cross the learned bar (or long-press-mark a word Learned), return to Coverage, and confirm the word moved from Learning → Learned and the coverage % rose. *(This confirms the shared `MasteryStage` reflects real review activity.)*

- [ ] **Step 4: Run the full test suite once more**

Run the entire `KiokuTests` suite.
Expected: all tests pass (existing + the 8 new tests from Tasks 1–3).

- [ ] **Step 5: Final commit / push if any verification fixes were needed**

```bash
git add -A
git commit -m "fix(learn): coverage verification fixes

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git push
```

*(If no fixes were needed, just `git push` the commits from the prior phases.)*

---

## Out of scope (deferred / not in this plan)

- **Cloze into the SRS.** Requires surface→entry-id resolution with deinflection and saved-word
  gating — its own small spec. Mastery here is driven by Flashcards + Multiple Choice, as today.
- **Stacked proportional bar visuals.** The level rows use count chips + a note-wide progress bar;
  a segmented per-level bar can be a later polish pass.
- **Learn-tab redesign around notes, per-mode mastery weighting, kanji coverage.** Explicitly out
  of scope per the design spec.
