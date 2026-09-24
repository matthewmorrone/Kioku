import SwiftUI

// Renders the Matching study mode: five words down the left, their answers shuffled down the
// right, tap one on each side to pair them. Shares the start screen, word pool and direction model
// with the other Learn activities; each board quizzes one direction (see MatchingRoundBuilder).
// Major sections: toolbar, session header (round, direction, tallies), the two-column board,
// review home form, summary.
struct MatchingView: View {
    let dictionaryStore: DictionaryStore?

    @EnvironmentObject private var wordsStore: WordsStore

    @State private var rounds: [MatchingRound] = []
    @State private var roundIndex: Int = 0
    @State private var sessionActive: Bool = false
    @State private var isResolving: Bool = false

    // The tile currently picked on each side, waiting for its partner.
    @State private var selectedPrompt: Int64?
    @State private var selectedAnswer: Int64?
    // Words paired off so far this session. Ids are unique across the session (each word is dealt
    // once), so these span rounds without being reset per board.
    @State private var matched: Set<Int64> = []
    // Words that had at least one wrong pairing — scored wrong once, and not scored again when they
    // are eventually matched.
    @State private var missed: Set<Int64> = []
    // The two tiles of the last wrong pairing, painted red briefly.
    @State private var wrongFlash: (prompt: Int64, answer: Int64)?
    // Pending move to the next board once this one is cleared; cancelled on End.
    @State private var advanceTask: Task<Void, Never>?

    // Note / JLPT / scope / direction / count, persisted under this activity's own key prefix.
    @StateObject private var options = LearnActivityOptions(activity: .matching)
    private let activity = LearnActivity.matching
    // Skip words already at the Learned/Mastered stage. Shared with the other Learn modes via
    // LearnedSettings; toggled in Settings → Learning. See StudyWordPool.
    @AppStorage(LearnedSettings.excludeLearnedKey) private var excludeLearned = LearnedSettings.defaultExcludeLearned

    var body: some View {
        NavigationStack {
            Group {
                if wordsStore.words.isEmpty {
                    emptySavedState
                } else if sessionActive == false {
                    reviewHome
                } else if isResolving {
                    resolvingState
                } else if roundIndex >= rounds.count {
                    sessionCompleteState
                } else {
                    VStack(spacing: 16) {
                        sessionHeader
                        Spacer(minLength: 8)
                        board(rounds[roundIndex])
                        Spacer(minLength: 8)
                    }
                    .padding()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                LearnHomeTitle(title: activity.title, systemImage: activity.systemImage)
                ToolbarItem(placement: .topBarLeading) {
                    if sessionActive {
                        Button { endSession() } label: {
                            Label("End", systemImage: "xmark.circle")
                        }
                    }
                }
            }
        }
        // Suppress the Learn tab page dots and swipe-between-modes while a session is in progress.
        .preference(key: CardsPageDotsHiddenPreferenceKey.self, value: sessionActive)
        .preference(key: CardsStudySessionActivePreferenceKey.self, value: sessionActive)
    }

    // Words right on the first try, and words that took more than one.
    private var sessionCorrect: Int { matched.subtracting(missed).count }
    private var sessionWrong: Int { missed.count }

    // Shows board position, the board's direction, and running correct/wrong tallies.
    private var sessionHeader: some View {
        HStack {
            Text("\(min(roundIndex + 1, rounds.count)) / \(rounds.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(rounds[roundIndex].direction.label)
                .font(.subheadline.weight(.medium))
            Spacer()
            HStack(spacing: 12) {
                Label("\(sessionWrong)", systemImage: "xmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Label("\(sessionCorrect)", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // The board: one row per pair, left tile from the prompts in order, right tile from the
    // shuffled answers. Laid out by row (not by column) so both sides of a row share a height.
    private func board(_ round: MatchingRound) -> some View {
        let fields = round.direction.fields
        let pairsByID = Dictionary(uniqueKeysWithValues: round.pairs.map { ($0.id, $0) })
        return VStack(spacing: 10) {
            ForEach(Array(round.pairs.enumerated()), id: \.element.id) { row, pair in
                HStack(spacing: 10) {
                    MatchingTile(
                        text: pair.prompt,
                        isMeaning: fields.prompt == .meaning,
                        state: tileState(.prompt, id: pair.id),
                        onTap: { tap(.prompt, id: pair.id, in: round) }
                    )
                    let answerID = round.answerOrder[row]
                    MatchingTile(
                        text: pairsByID[answerID]?.answer ?? "",
                        isMeaning: fields.answer == .meaning,
                        state: tileState(.answer, id: answerID),
                        onTap: { tap(.answer, id: answerID, in: round) }
                    )
                }
            }
        }
    }

    // How one tile is painted: matched beats a red flash beats a selection.
    private func tileState(_ column: MatchingColumn, id: Int64) -> MatchingTileState {
        if matched.contains(id) { return .matched }
        if let wrongFlash {
            let flashedID = column == .prompt ? wrongFlash.prompt : wrongFlash.answer
            if flashedID == id { return .wrong }
        }
        let selectedID = column == .prompt ? selectedPrompt : selectedAnswer
        return selectedID == id ? .selected : .idle
    }

    // Selects (or deselects) a tile on one side, then tries to pair it with the other side's pick.
    // Either side may be tapped first.
    private func tap(_ column: MatchingColumn, id: Int64, in round: MatchingRound) {
        guard matched.contains(id) == false else { return }
        wrongFlash = nil
        switch column {
        case .prompt: selectedPrompt = selectedPrompt == id ? nil : id
        case .answer: selectedAnswer = selectedAnswer == id ? nil : id
        }
        guard let prompt = selectedPrompt, let answer = selectedAnswer else { return }
        selectedPrompt = nil
        selectedAnswer = nil
        guard let pair = round.pairs.first(where: { $0.id == prompt }) else { return }

        if prompt == answer {
            matched.insert(prompt)
            // A word that already missed was scored when it missed; matching it now is just
            // clearing the board.
            if missed.contains(prompt) == false {
                wordsStore.recordCorrect(for: prompt, direction: round.direction, hasKanjiForm: pair.hasKanjiForm)
            }
            if round.pairs.allSatisfy({ matched.contains($0.id) }) {
                scheduleAdvance()
            }
        } else {
            // The left tile's word is the one being asked, so it takes the miss.
            if missed.insert(prompt).inserted {
                wordsStore.recordAgain(for: prompt, direction: round.direction, hasKanjiForm: pair.hasKanjiForm)
            }
            flashWrong(prompt: prompt, answer: answer)
        }
    }

    // Paints a wrong pairing red for a moment, then clears it unless another pairing replaced it.
    private func flashWrong(prompt: Int64, answer: Int64) {
        wrongFlash = (prompt, answer)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            if let current = wrongFlash, current.prompt == prompt, current.answer == answer {
                wrongFlash = nil
            }
        }
    }

    // Moves to the next board after a short beat, so the last match is seen landing.
    private func scheduleAdvance() {
        advanceTask?.cancel()
        advanceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard Task.isCancelled == false else { return }
            roundIndex += 1
        }
    }

    // Shown while the dictionary lookups that build the boards are in flight.
    private var resolvingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Preparing words…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Shown when the user has no saved words yet.
    private var emptySavedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "book").font(.largeTitle)
            Text("No saved words").font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Shown after the last board is cleared.
    private var sessionCompleteState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.largeTitle)
            Text("Matching complete").font(.headline)

            let total = sessionCorrect + sessionWrong
            HStack(spacing: 16) {
                Label("\(sessionCorrect) correct", systemImage: "checkmark.circle.fill")
                Label("\(sessionWrong) wrong", systemImage: "xmark.circle")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if total > 0 {
                Text("This session: \(Int((Double(sessionCorrect) / Double(total) * 100).rounded()))%")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Button { startSession() } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)

            Button { endSession() } label: {
                Label("Choose Different Cards", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // The shared start screen — identical for every activity.
    private var reviewHome: some View {
        LearnActivityHome(
            activity: activity,
            options: options,
            dictionaryStore: dictionaryStore,
            pool: pool(),
            onStart: { startSession() }
        )
    }

    // Words passing every filter and askable in at least one selected direction, plus the count
    // the learned exclusion held back.
    private func pool() -> StudyWordSelection {
        LearnWordPool.eligible(
            in: wordsStore.words, options: options, excludeLearned: excludeLearned,
            wordsStore: wordsStore, dictionaryStore: dictionaryStore
        )
    }

    // Resolves the pool's display strings, caps it to the session length, deals the boards, and
    // activates the session.
    private func startSession() {
        advanceTask?.cancel()
        sessionActive = true
        isResolving = true
        resetBoardState()
        rounds = []
        let words = pool().words
        let selection = options.directions
        let limit = options.count
        Task {
            let items = await LearnWordPool.resolveItems(for: words, dictionaryStore: dictionaryStore)
            // A positive limit caps the words dealt; 0 means every word in the pool.
            let capped = limit > 0 ? Array(items.shuffled().prefix(limit)) : items
            var generator = SystemRandomNumberGenerator()
            rounds = MatchingRoundBuilder.build(from: capped, selection: selection, using: &generator)
            isResolving = false
        }
    }

    // Clears all session state, returning to the home screen.
    private func endSession() {
        advanceTask?.cancel()
        advanceTask = nil
        sessionActive = false
        isResolving = false
        rounds = []
        resetBoardState()
    }

    // Clears per-session progress: position, picks, and scoring.
    private func resetBoardState() {
        roundIndex = 0
        selectedPrompt = nil
        selectedAnswer = nil
        matched = []
        missed = []
        wrongFlash = nil
    }
}
