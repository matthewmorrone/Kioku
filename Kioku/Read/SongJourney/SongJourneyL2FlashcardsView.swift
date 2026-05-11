import SwiftUI

// L2 stage: a flashcard session scoped to one song's saved words. Reuses FlashcardCard and
// records grading through the shared ReviewStore so this counts as real study, unlike the
// short diagnostic probe.
struct SongJourneyL2FlashcardsView: View {
    let note: Note
    let words: [SavedWord]
    let dictionaryStore: DictionaryStore?
    let onFinish: (_ score: Double) -> Void

    @EnvironmentObject private var reviewStore: ReviewStore

    @State private var session: [SavedWord] = []
    @State private var index: Int = 0
    @State private var showBack: Bool = false
    @State private var dragOffset: CGSize = .zero
    @State private var isSwipingOut: Bool = false
    @State private var swipeDirection: Int = 0
    @State private var correct: Int = 0
    @State private var again: Int = 0
    @State private var reviewedCount: Int = 0
    @State private var totalCount: Int = 0
    @State private var hasFinished = false

    private let direction: FlashcardCardDirection = .kanaToEnglish

    var body: some View {
        VStack(spacing: 16) {
            if words.isEmpty {
                emptyState
            } else if hasFinished {
                completionState
            } else if session.isEmpty {
                ProgressView()
            } else {
                header
                Spacer(minLength: 8)
                cardStack
                Spacer(minLength: 8)
                controls
            }
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Image(systemName: SongJourneyStage.l2Flashcards.sfSymbol)
                    Text(SongJourneyStage.l2Flashcards.displayName)
                }
                .font(.headline)
                .foregroundStyle(.primary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if session.isEmpty == false && hasFinished == false {
                    Button { finishEarly() } label: { Label("End", systemImage: "checkmark.circle") }
                }
            }
        }
        .onAppear { startSession() }
    }

    private var header: some View {
        HStack {
            Text("\(min(reviewedCount + 1, totalCount)) / \(totalCount)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Label("\(again)", systemImage: "arrow.uturn.left.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Label("\(correct)", systemImage: "checkmark.circle.fill")
                .font(.footnote)
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
                    onKnow: { handleKnow() },
                    onAgain: { handleAgain() }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 360)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button { handleAgain() } label: {
                Label("Again", systemImage: "arrow.uturn.left.circle")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            Spacer()
            Button { handleKnow() } label: {
                Label("Know", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "book").font(.largeTitle)
            Text("No saved words yet").font(.headline)
            Text("Tap-save words from the Listen stage first.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var completionState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundStyle(.green)
            Text("Session complete").font(.headline)
            HStack(spacing: 16) {
                Label("\(correct) correct", systemImage: "checkmark.circle.fill")
                Label("\(again) again", systemImage: "arrow.uturn.left.circle")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Button { onFinish(currentScore()) } label: {
                Label("Save score & return", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.borderedProminent)
            Button { restart() } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Builds a fresh session queue (shuffled) on first appear or after a restart.
    private func startSession() {
        guard session.isEmpty, words.isEmpty == false else { return }
        session = words.shuffled()
        totalCount = session.count
        index = 0
        correct = 0
        again = 0
        reviewedCount = 0
        showBack = false
        hasFinished = false
    }

    // Resets the session so the user can re-run the same set of cards after the completion screen.
    private func restart() {
        session = []
        startSession()
    }

    // Records a correct answer, removes the card, and ends the session when the queue empties.
    // Unlike the diagnostic, this updates ReviewStore because L2 is real study.
    private func handleKnow() {
        guard session.isEmpty == false else { return }
        correct += 1
        reviewedCount += 1
        reviewStore.recordCorrect(for: session[index].canonicalEntryID)
        session.remove(at: index)
        if session.isEmpty {
            finish()
            return
        }
        if index >= session.count { index = max(0, session.count - 1) }
        showBack = false
    }

    // Records "again" and recirculates the card to the back of the queue so the user sees it again.
    private func handleAgain() {
        guard session.isEmpty == false else { return }
        again += 1
        reviewedCount += 1
        let w = session[index]
        reviewStore.recordAgain(for: w.canonicalEntryID)
        session.remove(at: index)
        session.append(w)
        if index >= session.count { index = session.count - 1 }
        showBack = false
    }

    // Lets the user stop mid-session and grade with whatever they've answered so far.
    private func finishEarly() {
        guard hasFinished == false else { return }
        finish()
    }

    // Flips into the completion state. The parent records the score when the user dismisses.
    private func finish() {
        hasFinished = true
    }

    // Correct-over-total accuracy used as this stage's score. max(1, _) avoids divide-by-zero
    // when the user finishes without answering any cards (treated as 0%).
    private func currentScore() -> Double {
        let total = max(1, correct + again)
        return Double(correct) / Double(total)
    }
}
