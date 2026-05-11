import SwiftUI

// Short flashcard probe (up to 5 cards) that suggests the best stage to start at for this song.
// Reuses FlashcardCard directly. Deliberately does NOT touch ReviewStore — the probe should not
// distort the user's lifetime accuracy.
struct SongJourneyDiagnosticView: View {
    let note: Note
    let words: [SavedWord]
    let dictionaryStore: DictionaryStore?
    let onFinish: (_ score: Double, _ recommendedStage: SongJourneyStage) -> Void

    @State private var session: [SavedWord] = []
    @State private var index: Int = 0
    @State private var showBack: Bool = false
    @State private var dragOffset: CGSize = .zero
    @State private var isSwipingOut: Bool = false
    @State private var swipeDirection: Int = 0
    @State private var correct: Int = 0
    @State private var again: Int = 0
    @State private var hasSubmittedResult = false

    private let direction: FlashcardCardDirection = .kanaToEnglish
    private let maxCards = 5

    var body: some View {
        VStack(spacing: 16) {
            if session.isEmpty == false {
                header
                Spacer(minLength: 8)
                cardStack
                Spacer(minLength: 8)
                controls
            } else if hasSubmittedResult {
                // Brief stub between scoring and the parent popping the navigation stack.
                ProgressView()
            } else {
                emptyState
            }
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Image(systemName: SongJourneyStage.diagnostic.sfSymbol)
                    Text(SongJourneyStage.diagnostic.displayName)
                }
                .font(.headline)
                .foregroundStyle(.primary)
            }
        }
        .onAppear {
            if session.isEmpty {
                session = Array(words.shuffled().prefix(maxCards))
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Card \(min(index + 1, session.count)) / \(session.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text("This probe doesn't affect your stats.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var cardStack: some View {
        let end = min(index + 3, session.count)
        let visible = Array(session[index..<end])
        let topID = session.indices.contains(index) ? session[index].canonicalEntryID : nil
        return ZStack {
            ForEach(visible.reversed()) { word in
                FlashcardCard(
                    word: word,
                    dictionaryStore: dictionaryStore,
                    isTop: word.canonicalEntryID == topID,
                    direction: direction,
                    preferredNoteID: note.id,
                    showBack: $showBack,
                    dragOffset: $dragOffset,
                    isSwipingOut: $isSwipingOut,
                    swipeDirection: $swipeDirection,
                    onKnow: { recordKnow() },
                    onAgain: { recordAgain() }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 360)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button { recordAgain() } label: {
                Label("Don't know", systemImage: "questionmark.circle")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            Spacer()
            Button { recordKnow() } label: {
                Label("Know", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "stethoscope").font(.largeTitle)
            Text("Nothing to probe yet").font(.headline)
            Text("Save some words from the song first, then come back.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Counts the card as known. Deliberately does not call ReviewStore — diagnostic results must
    // not pollute the user's lifetime accuracy.
    private func recordKnow() {
        guard index < session.count else { return }
        correct += 1
        advance()
    }

    // Counts the card as unknown. Same rationale as recordKnow — diagnostic is probe-only.
    private func recordAgain() {
        guard index < session.count else { return }
        again += 1
        advance()
    }

    // Moves to the next card and triggers finish() once the queue is exhausted.
    private func advance() {
        showBack = false
        index += 1
        if index >= session.count {
            finish()
        }
    }

    // Maps the diagnostic score to a recommended starting stage so the journey screen can
    // surface "Start here" on the most useful card next time the user opens the song.
    private func finish() {
        guard hasSubmittedResult == false else { return }
        hasSubmittedResult = true
        let total = max(1, correct + again)
        let score = Double(correct) / Double(total)
        let recommended: SongJourneyStage
        if score >= 0.8 {
            recommended = .l3Cloze
        } else if score >= 0.4 {
            recommended = .l2Flashcards
        } else {
            recommended = .l1Listen
        }
        onFinish(score, recommended)
    }
}
