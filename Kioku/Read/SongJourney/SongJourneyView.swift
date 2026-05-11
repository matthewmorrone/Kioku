import SwiftUI

// Host screen for the per-song learning journey. Lists the five stages as cards and routes into
// the existing study views (flashcards, cloze) for each one. Major sections: stage list, target
// vocabulary preview, navigation destinations for diagnostic / L2 / L3 / Mastery.
//
// L1 is the only stage that does not push a destination — the karaoke LyricsView is already an
// overlay on ReadView, so this view dismisses itself and calls `onRequestL1Listen` rather than
// presenting a sheet-inside-a-sheet.
struct SongJourneyView: View {
    let note: Note
    let dictionaryStore: DictionaryStore?
    let onRequestL1Listen: () -> Void
    let onDismiss: () -> Void

    @EnvironmentObject private var songJourneyStore: SongJourneyStore
    @EnvironmentObject private var wordsStore: WordsStore

    @State private var navigationPath = NavigationPath()

    // Saved words tagged to this note — the song's "target vocab list". Derived, not stored.
    private var songWords: [SavedWord] {
        wordsStore.words.filter { $0.sourceNoteIDs.contains(note.id) }
    }

    private var currentState: SongJourneyState {
        songJourneyStore.state(for: note.id)
    }

    private var recommendedStage: SongJourneyStage {
        currentState.recommendedStartStage ?? .l1Listen
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                LazyVStack(spacing: 12) {
                    headerCard
                    ForEach(SongJourneyStage.allCases) { stage in
                        SongJourneyStageCard(
                            stage: stage,
                            state: currentState,
                            isRecommended: stage == recommendedStage && currentState.isCompleted(stage) == false,
                            action: { handleStageTapped(stage) }
                        )
                    }
                    if songWords.isEmpty == false {
                        targetVocabSection
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "graduationcap.fill")
                        Text("Song Journey")
                    }
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Song Journey")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onDismiss() }
                }
            }
            .navigationDestination(for: SongJourneyRoute.self) { route in
                destination(for: route)
            }
        }
    }

    // Single-line song title + per-song saved-word count, so users see the journey scope at a glance.
    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.title.isEmpty ? "Untitled song" : note.title)
                .font(.title3.weight(.semibold))
            Text("\(songWords.count) saved word\(songWords.count == 1 ? "" : "s") from this song")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    // Wrapping chip cloud of the song's saved words. Shown only when there is at least one word.
    private var targetVocabSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Target vocabulary")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            SongJourneyVocabChips(items: songWords.prefix(24).map { $0.surface })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // Routes each pushed destination to its stage view, mediating completion callbacks so this
    // view (not the child) owns the journey-state writes for that stage.
    @ViewBuilder
    private func destination(for route: SongJourneyRoute) -> some View {
        switch route {
        case .diagnostic:
            SongJourneyDiagnosticView(
                note: note,
                words: songWords,
                dictionaryStore: dictionaryStore,
                onFinish: { score, recommended in
                    songJourneyStore.recordScore(noteID: note.id, stage: .diagnostic, score: score)
                    songJourneyStore.setRecommendedStart(noteID: note.id, stage: recommended)
                    if navigationPath.isEmpty == false { navigationPath.removeLast() }
                }
            )
        case .l2Flashcards:
            SongJourneyL2FlashcardsView(
                note: note,
                words: songWords,
                dictionaryStore: dictionaryStore,
                onFinish: { score in
                    songJourneyStore.recordScore(noteID: note.id, stage: .l2Flashcards, score: score)
                    if navigationPath.isEmpty == false { navigationPath.removeLast() }
                }
            )
        case .l3Cloze:
            SongJourneyClozeStageView(
                note: note,
                stage: .l3Cloze,
                blanksPerSentence: 1,
                mode: .sequential,
                minimumAnswered: 4,
                onFinish: { score in
                    songJourneyStore.recordScore(noteID: note.id, stage: .l3Cloze, score: score)
                    if navigationPath.isEmpty == false { navigationPath.removeLast() }
                }
            )
        case .mastery:
            SongJourneyClozeStageView(
                note: note,
                stage: .mastery,
                blanksPerSentence: 3,
                mode: .random,
                minimumAnswered: 8,
                onFinish: { score in
                    songJourneyStore.recordScore(noteID: note.id, stage: .mastery, score: score)
                    if navigationPath.isEmpty == false { navigationPath.removeLast() }
                }
            )
        }
    }

    // Records the user's last-active stage and either pushes a destination or dismisses to the
    // LyricsView overlay (L1). Diagnostic is a no-op when there are no saved words to probe.
    private func handleStageTapped(_ stage: SongJourneyStage) {
        songJourneyStore.setLastActive(noteID: note.id, stage: stage)
        switch stage {
        case .diagnostic:
            if songWords.isEmpty {
                songJourneyStore.setRecommendedStart(noteID: note.id, stage: .l1Listen)
                return
            }
            navigationPath.append(SongJourneyRoute.diagnostic)
        case .l1Listen:
            songJourneyStore.markVisited(noteID: note.id, stage: .l1Listen)
            onRequestL1Listen()
        case .l2Flashcards:
            navigationPath.append(SongJourneyRoute.l2Flashcards)
        case .l3Cloze:
            navigationPath.append(SongJourneyRoute.l3Cloze)
        case .mastery:
            navigationPath.append(SongJourneyRoute.mastery)
        }
    }
}
