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
    // Every identity SegmentListView's vocabRowCountsAsSaved marks as already-saved-for-this-note
    // — the exact rule backing Vocab's "N already saved" count. `coverage` filters against this
    // directly instead of independently re-deriving its own sourceNoteIDs/encounteredSurfaces
    // logic, so the two screens' totals can't drift apart from two separately-coded versions of
    // "is this word attributed to this note."
    let savedIdentitiesForThisNote: Set<String>

    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var notesStore: NotesStore
    @EnvironmentObject private var reviewStore: ReviewStore
    @EnvironmentObject private var wordListsStore: WordListsStore

    @State private var pendingWords: [SavedWord] = []
    @State private var showModeChooser = false
    @State private var launch: CoverageLaunch?
    // Which level rows are expanded to show their word list — keyed by the same optional JLPT
    // N-number as NoteCoverageLevel.level, so "No level" (nil) can be tracked too.
    @State private var expandedLevels: Set<Int?> = []
    // The word chip tapped in an expanded level's word list — presents its WordDetailView.
    @State private var selectedWord: SavedWord?

    // The live coverage grid for this note, recomputed from the stores on each render. A word
    // counts toward this note exactly when its surface is in savedIdentitiesForThisNote — the
    // same rule Vocab's chip cloud uses, so this total is always the same number Vocab shows as
    // already-saved, never an independently-derived approximation of it.
    private var coverage: NoteCoverage {
        let words = wordsStore.words.filter { word in
            word.encounteredSurfaces.contains {
                savedIdentitiesForThisNote.contains($0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return NoteCoverageCalculator.compute(
            words: words,
            level: { dictionaryStore?.jlptLevel(for: $0) },
            stage: { reviewStore.masteryStage(for: $0) },
            isDue: { reviewStore.isDueForReview(id: $0) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                summaryCard
                levelsCard
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .confirmationDialog("Study these words with…", isPresented: $showModeChooser, titleVisibility: .visible) {
            Button("Flashcards") { launch = CoverageLaunch(words: pendingWords, mode: .flashcards) }
            Button("Multiple Choice") { launch = CoverageLaunch(words: pendingWords, mode: .multipleChoice) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $launch) { launch in
            studySheet(for: launch)
        }
        .sheet(item: $selectedWord) { word in
            WordDetailView(word: word, reading: nil, dictionaryStore: dictionaryStore, segmenter: nil, noteID: note.id)
                .environmentObject(wordsStore)
                .environmentObject(wordListsStore)
                .presentationDetents([.large])
        }
    }

    // Note-wide summary: "N of M learned (P%)" with a progress bar, and a due-count callout.
    private var summaryCard: some View {
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // Every level stacked in a single card (one rounded rectangle, thin dividers between rows)
    // instead of one List Section per level — that gave each level its own header/footer inset,
    // which added up to more empty chrome than content on notes with several levels present.
    private var levelsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(coverage.levels.enumerated()), id: \.element.level) { index, level in
                if index > 0 {
                    Divider().padding(.leading, 14)
                }
                levelRow(level)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // One level row: a single tappable header line (level label + "x/y learned" caption +
    // chevron) that expands to reveal the word list, plus the three stage chips. Collapsing the
    // header and chevron into one line (instead of a full-width chevron button below the chips)
    // removes a whole row's worth of height per level.
    private func levelRow(_ level: NoteCoverageLevel) -> some View {
        let isExpanded = expandedLevels.contains(level.level)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isExpanded {
                        expandedLevels.remove(level.level)
                    } else {
                        expandedLevels.insert(level.level)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(levelTitle(level.level))
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 48, alignment: .leading)
                    Text("\(level.learnedCount)/\(level.total) learned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                stageChip(level, .new, "New")
                stageChip(level, .learning, "Learning")
                stageChip(level, .learned, "Learned")
            }

            if isExpanded {
                wordList(level)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // The expanded word list for a level: every word rendered as a small wrapping chip, tinted by
    // its own mastery stage (see stageColor) instead of grouped under New/Learning/Learned text
    // headers — the color carries the distinction, so the chips read as distinct at a glance
    // without needing a label to sort them into. Tapping a chip opens that word's WordDetailView.
    private func wordList(_ level: NoteCoverageLevel) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(MasteryStage.allCases, id: \.self) { stage in
                ForEach(level.words(in: stage)) { word in
                    Button {
                        selectedWord = word
                    } label: {
                        Text(word.surface)
                            .font(.subheadline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(stageColor(stage).opacity(0.25), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // Traffic-light progression from unstarted to mastered, used to tint word chips in wordList.
    private func stageColor(_ stage: MasteryStage) -> Color {
        switch stage {
        case .new: return .gray
        case .learning: return .orange
        case .learned: return .green
        }
    }

    // A single tappable stage chip. Tapping a non-empty chip resolves its words and opens the
    // mode chooser; an empty chip is disabled.
    private func stageChip(_ level: NoteCoverageLevel, _ stage: MasteryStage, _ title: String) -> some View {
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
