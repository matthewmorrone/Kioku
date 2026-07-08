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
